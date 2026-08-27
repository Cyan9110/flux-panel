package com.admin.common.dto;


import lombok.Data;

import java.util.Map;

@Data
public class ConfigItem {
    private String name;

    /** 服务处理器配置，用于检查节点配置是否与数据库一致。 */
    private Map<String, Object> handler;
}

