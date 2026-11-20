package com.admin.common.task;

import com.admin.common.dto.*;
import com.admin.common.utils.GostUtil;
import com.admin.entity.*;
import com.admin.service.*;
import com.alibaba.fastjson.JSONObject;
import com.alibaba.fastjson.JSONArray;
import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Lazy;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;

import javax.annotation.Resource;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.stream.Collectors;

@Slf4j
@Service
public class CheckGostConfigAsync {

    @Resource
    private NodeService nodeService;

    @Resource
    @Lazy
    private ForwardService forwardService;

    @Resource
    @Lazy
    private SpeedLimitService speedLimitService;

    @Resource
    @Lazy
    private TunnelService tunnelService;

    @Resource
    private UserTunnelService userTunnelService;



    /**
     * 清理孤立的Gost配置项
     */
    @Async
    public void cleanNodeConfigs(String node_id, GostConfigDto gostConfig) {
        System.out.println(JSONObject.toJSONString(gostConfig));
        Node node = nodeService.getById(node_id);
        if (node != null) {
            cleanOrphanedServices(gostConfig, node);
            cleanOrphanedChains(gostConfig, node);
            cleanOrphanedLimiters(gostConfig, node);
            JSONArray missingLimiters = collectMissingLimiters(gostConfig, node);
            syncMissingForwards(gostConfig, node, missingLimiters);
        }
    }

    /**
     * 新节点或配置丢失的节点上线后，根据数据库补齐其应承担的转发组件。
     */
    private void syncMissingForwards(GostConfigDto gostConfig, Node node, JSONArray missingLimiters) {
        Map<Long, Tunnel> relatedTunnels = new LinkedHashMap<>();
        tunnelService.list(new QueryWrapper<Tunnel>().eq("in_node_id", node.getId()))
                .forEach(tunnel -> relatedTunnels.put(tunnel.getId(), tunnel));
        tunnelService.list(new QueryWrapper<Tunnel>().eq("out_node_id", node.getId()))
                .forEach(tunnel -> relatedTunnels.put(tunnel.getId(), tunnel));

        if (relatedTunnels.isEmpty() && missingLimiters.isEmpty()) {
            return;
        }

        Set<String> serviceNames = configNames(gostConfig.getServices());
        Set<String> chainNames = configNames(gostConfig.getChains());
        List<Forward> forwards = forwardService.list(new QueryWrapper<Forward>()
                .in("tunnel_id", relatedTunnels.keySet())
                .eq("status", 1));

        JSONArray services = new JSONArray();
        JSONArray chains = new JSONArray();
        JSONArray deleteServices = new JSONArray();
        List<Long> syncedForwardIds = new ArrayList<>();

        for (Forward forward : forwards) {
            Tunnel tunnel = relatedTunnels.get(forward.getTunnelId().longValue());
            if (tunnel == null) {
                continue;
            }

            String prefix = forward.getId() + "_" + forward.getUserId() + "_";
            boolean missing = false;
            boolean removeUnexpectedUdp = false;
            if (Objects.equals(tunnel.getInNodeId(), node.getId())) {
                ConfigItem tcpService = findItem(gostConfig.getServices(), prefix, "_tcp");
                ConfigItem udpService = findItem(gostConfig.getServices(), prefix, "_udp");
                boolean expectUdp = shouldIncludeUdp(forward.getProxyProtocol());
                boolean missingMainService = tcpService == null || (expectUdp && udpService == null);
                boolean unexpectedUdpService = !expectUdp && udpService != null;
                removeUnexpectedUdp = unexpectedUdpService;
                boolean proxyProtocolMismatch = tcpService != null
                        && getProxyProtocol(tcpService) != expectedProxyProtocol(forward.getProxyProtocol());
                boolean missingChain = tunnel.getType() == 2
                        && !containsName(chainNames, prefix, "_chains");
                missing = missingMainService || unexpectedUdpService || proxyProtocolMismatch || missingChain;
            }
            if (tunnel.getType() == 2 && Objects.equals(tunnel.getOutNodeId(), node.getId())) {
                missing = missing || !containsName(serviceNames, prefix, "_tls");
            }

            if (missing) {
                UserTunnel userTunnel = userTunnelService.getOne(new QueryWrapper<UserTunnel>()
                        .eq("user_id", forward.getUserId())
                        .eq("tunnel_id", tunnel.getId()));
                Integer limiter = userTunnel == null ? null : userTunnel.getSpeedId();
                int userTunnelId = userTunnel == null ? 0 : userTunnel.getId();
                String serviceName = forward.getId() + "_" + forward.getUserId() + "_" + userTunnelId;

                if (Objects.equals(tunnel.getInNodeId(), node.getId())) {
                    if (tunnel.getType() == 2) {
                        String remoteAddr = tunnel.getOutIp() + ":" + forward.getOutPort();
                        chains.add(GostUtil.BuildChain(serviceName, remoteAddr,
                                tunnel.getProtocol(), tunnel.getInterfaceName()));
                    }
                    String interfaceName = tunnel.getType() == 2 ? null : forward.getInterfaceName();
                    services.addAll(GostUtil.BuildServices(serviceName, forward.getInPort(), limiter,
                            forward.getRemoteAddr(), tunnel.getType(), tunnel, forward.getStrategy(),
                            interfaceName, forward.getProxyProtocol()));
                    if (removeUnexpectedUdp) {
                        deleteServices.add(serviceName + "_udp");
                    }
                }
                if (tunnel.getType() == 2 && Objects.equals(tunnel.getOutNodeId(), node.getId())) {
                    services.add(GostUtil.BuildRemoteService(serviceName, forward.getOutPort(),
                            forward.getRemoteAddr(), tunnel.getProtocol(), forward.getStrategy(),
                            forward.getInterfaceName()));
                }
                syncedForwardIds.add(forward.getId());
            }
        }

        if (services.isEmpty() && chains.isEmpty() && missingLimiters.isEmpty() && deleteServices.isEmpty()) {
            return;
        }

        GostDto result = GostUtil.BatchSync(node.getId(), services, chains, missingLimiters, deleteServices);
        if (result == null || !Objects.equals(result.getMsg(), "OK")) {
            String message = result == null ? "无响应" : result.getMsg();
            throw new IllegalStateException("批量同步节点 " + node.getId() + " 失败: " + message);
        }
        log.info("节点 {} 批量同步完成: {} 个转发, {} 个服务, {} 个链, {} 个限流器",
                node.getId(), syncedForwardIds.size(), services.size(), chains.size(), missingLimiters.size());
    }

    private Set<String> configNames(List<ConfigItem> items) {
        if (items == null) {
            return java.util.Collections.emptySet();
        }
        return items.stream()
                .map(ConfigItem::getName)
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());
    }

    private boolean containsName(Set<String> names, String prefix, String suffix) {
        return names.stream().anyMatch(name -> name.startsWith(prefix) && name.endsWith(suffix));
    }

    private ConfigItem findItem(List<ConfigItem> items, String prefix, String suffix) {
        if (items == null) {
            return null;
        }
        return items.stream()
                .filter(Objects::nonNull)
                .filter(item -> item.getName() != null
                        && item.getName().startsWith(prefix)
                        && item.getName().endsWith(suffix))
                .findFirst()
                .orElse(null);
    }

    private boolean shouldIncludeUdp(Integer proxyProtocol) {
        return proxyProtocol == null
                || proxyProtocol == 0
                || proxyProtocol == 2;
    }

    private int expectedProxyProtocol(Integer proxyProtocol) {
        if (proxyProtocol == null || proxyProtocol == 0) {
            return 0;
        }
        return proxyProtocol == 1 ? 1 : 2;
    }

    private int getProxyProtocol(ConfigItem service) {
        if (service.getHandler() == null) {
            return 0;
        }
        Object metadataObject = service.getHandler().get("metadata");
        if (!(metadataObject instanceof Map)) {
            return 0;
        }
        Object value = ((Map<?, ?>) metadataObject).get("proxyProtocol");
        if (value instanceof Number) {
            return ((Number) value).intValue();
        }
        if (value != null) {
            try {
                return Integer.parseInt(value.toString());
            } catch (NumberFormatException ignored) {
                return 0;
            }
        }
        return 0;
    }

    /**
     * 清理孤立的服务
     */
    private void cleanOrphanedServices(GostConfigDto gostConfig, Node node) {
        if (gostConfig.getServices() == null) {
            return;
        }

        for (ConfigItem service : gostConfig.getServices()) {
            safeExecute(() -> {

                if (!Objects.equals(service.getName(), "web_api")){
                    String[] serviceIds = parseServiceName(service.getName());
                    if (serviceIds.length == 4) {
                        String forwardId = serviceIds[0];
                        String userId = serviceIds[1];
                        String userTunnelId = serviceIds[2];
                        String type = serviceIds[3];

                        if (Objects.equals(type, "tcp")) { // 只处理TCP，避免重复处理
                            Forward forward = forwardService.getById(forwardId);
                            if (forward == null) {
                                log.info("删除孤立的服务: {} (节点: {})", service.getName(), node.getId());
                                GostDto gostDto = GostUtil.DeleteService(node.getId(), forwardId + "_" + userId + "_" + userTunnelId);
                                System.out.println(gostDto);
                            }
                        }


                        if (Objects.equals(type, "tls")) {
                            Forward forward = forwardService.getById(forwardId);
                            if (forward == null) {
                                log.info("删除孤立的服务: {} (节点: {})", service.getName(), node.getId());
                                GostUtil.DeleteRemoteService(node.getId(), forwardId+"_"+userId+"_"+userTunnelId);
                            }
                        }

                    }
                }


            }, "清理服务 " + service.getName());
        }

    }

    /**
     * 清理孤立的链
     */
    private void cleanOrphanedChains(GostConfigDto gostConfig, Node node) {
        if (gostConfig.getChains() == null) {
            return;
        }
        

        for (ConfigItem chain : gostConfig.getChains()) {
            safeExecute(() -> {
                String[] serviceIds = parseServiceName(chain.getName());
                if (serviceIds.length == 4) {
                    String forwardId = serviceIds[0];
                    String userId = serviceIds[1];
                    String userTunnelId = serviceIds[2];
                    String type = serviceIds[3];
                    
                    if (Objects.equals(type, "chains")) {
                        Forward forward = forwardService.getById(forwardId);
                        if (forward == null) {
                            log.info("删除孤立的链: {} (节点: {})", chain.getName(), node.getId());
                            GostUtil.DeleteChains(node.getId(), forwardId+"_"+userId+"_"+userTunnelId);
                        }
                    }
                }
            }, "清理链 " + chain.getName());
        }
    }

    /**
     * 清理孤立的限流器
     */
    private void cleanOrphanedLimiters(GostConfigDto gostConfig, Node node) {
        if (gostConfig.getLimiters() == null) {
            return;
        }
        

        for (ConfigItem limiter : gostConfig.getLimiters()) {
            safeExecute(() -> {
                SpeedLimit speedLimit = speedLimitService.getById(limiter.getName());
                if (speedLimit == null) {
                    log.info("删除孤立的限流器: {} (节点: {})", limiter.getName(), node.getId());
                    GostUtil.DeleteLimiters(node.getId(), Long.parseLong(limiter.getName()));
                }
            }, "清理限流器 " + limiter.getName());
        }
    }

    /**
     * 同步限流器
     */
    private JSONArray collectMissingLimiters(GostConfigDto gostConfig, Node node) {
        JSONArray missingLimiters = new JSONArray();
        List<Tunnel> tunnelList = tunnelService.list(new QueryWrapper<Tunnel>().eq("in_node_id", node.getId()));
        if (tunnelList == null || tunnelList.isEmpty()) return missingLimiters;
        safeExecute(() -> {
            List<Long> tunnelIds = tunnelList.stream().map(Tunnel::getId).collect(Collectors.toList());
            List<SpeedLimit> speedLimits = speedLimitService.list(
                    new QueryWrapper<SpeedLimit>().in("tunnel_id", tunnelIds));
            if (speedLimits != null && !speedLimits.isEmpty()) {
                List<ConfigItem> limiters = gostConfig.getLimiters();
                List<Long> limiters_ids = new ArrayList<>();
                List<Long>  speedLimits_ids = new ArrayList<>();
                if (limiters != null){
                    for (ConfigItem limiter : limiters) {
                        limiters_ids.add(Long.valueOf(limiter.getName()));
                    }
                }
                for (SpeedLimit speedLimit : speedLimits) {
                    speedLimits_ids.add(speedLimit.getId());
                }
                List<Long> diff = new ArrayList<>(speedLimits_ids);
                diff.removeAll(limiters_ids);
                System.out.println(diff);
                if (!diff.isEmpty()) {

                    for (Long speed_id : diff) {
                        SpeedLimit speedLimit = speedLimitService.getById(speed_id);
                        if (speedLimit != null) {
                            missingLimiters.add(GostUtil.BuildLimiter(
                                    speedLimit.getId(), String.valueOf(speedLimit.getSpeed())));
                        }
                    }
                }
            }
        }, "同步限流器 ");
        return missingLimiters;
    }

    /**
     * 安全执行操作，捕获异常
     */
    private void safeExecute(Runnable operation, String operationDesc) {
        try {
            operation.run();
        } catch (Exception e) {
            log.info("执行操作失败: {}", operationDesc, e);
        }
    }


    /**
     * 解析服务名称
     */
    private String[] parseServiceName(String serviceName) {
        return serviceName.split("_");
    }
}
