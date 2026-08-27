package com.admin.common.dto;

import lombok.Data;

import javax.validation.constraints.Max;
import javax.validation.constraints.Min;
import javax.validation.constraints.NotEmpty;
import javax.validation.constraints.NotNull;
import javax.validation.constraints.Size;
import java.util.List;

@Data
public class ForwardBatchProxyProtocolDto {

    @NotEmpty(message = "请选择至少一个转发")
    @Size(max = 500, message = "单次最多选择500个转发")
    private List<@NotNull(message = "转发ID不能为空") Long> ids;

    @NotNull(message = "PROXY Protocol版本不能为空")
    @Min(value = 0, message = "PROXY Protocol版本无效")
    @Max(value = 2, message = "PROXY Protocol版本无效")
    private Integer proxyProtocol;
}
