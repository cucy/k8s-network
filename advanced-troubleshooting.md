# Kubernetes服务网络高级排查指南

本文档提供了针对Kubernetes服务网络问题的深度排查技术和方法，适用于已经掌握基础知识的SRE、运维工程师和Kubernetes管理员。

## 目录

- [服务网络架构回顾](#服务网络架构回顾)
- [深入理解kube-proxy](#深入理解kube-proxy)
- [iptables规则分析](#iptables规则分析)
- [IPVS模式排查](#ipvs模式排查)
- [连接跟踪问题](#连接跟踪问题)
- [DNS深度排查](#dns深度排查)
- [NetworkPolicy排查](#networkpolicy排查)
- [节点级网络问题](#节点级网络问题)
- [CNI插件相关问题](#cni插件相关问题)
- [高级调试工具](#高级调试工具)
- [性能问题诊断](#性能问题诊断)
- [真实案例分析](#真实案例分析)

## 服务网络架构回顾

Kubernetes服务网络涉及多个组件的协同工作：

1. **kube-apiserver**: 处理Service资源对象的CRUD操作
2. **kube-controller-manager**: 包含EndpointController和EndpointSliceController，负责维护Endpoints/EndpointSlices
3. **kube-proxy**: 在每个节点上运行，监听Service和Endpoints变化，配置网络规则
4. **CoreDNS/KubeDNS**: 提供集群内DNS解析，将Service名称解析为ClusterIP
5. **CNI插件**: 提供Pod网络连通性，不同CNI插件可能对Service网络有不同影响

理解这些组件之间的交互对于深度排查至关重要。

## 深入理解kube-proxy

kube-proxy是Service网络实现的核心组件，它支持三种模式：

### userspace模式（已基本弃用）
- 工作在用户空间
- 性能较差，每个连接都需要在用户空间和内核空间之间切换

### iptables模式（默认）
- 使用Linux内核的iptables规则实现流量转发
- 无需在用户空间处理数据包
- 规则链路复杂，大规模集群下性能下降明显

### IPVS模式
- 使用Linux内核的IPVS模块
- 设计用于负载均衡，性能更好
- 支持更多负载均衡算法

排查kube-proxy问题的关键步骤：

1. 检查kube-proxy运行状态
```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl logs -n kube-system -l k8s-app=kube-proxy
```

2. 检查kube-proxy配置
```bash
kubectl get cm -n kube-system kube-proxy -o yaml
```

3. 检查kube-proxy指标（如果启用了metrics）
```bash
kubectl port-forward -n kube-system <kube-proxy-pod> 10249:10249
curl http://localhost:10249/metrics
```

## iptables规则分析

iptables模式下，Service网络规则可能非常复杂，特别是在大型集群中。

### 关键iptables链

- **KUBE-SERVICES**: 所有Service的入口点
- **KUBE-SVC-XXX**: 特定Service的规则链，实现负载均衡
- **KUBE-SEP-XXX**: 特定Endpoint的规则链，指向具体Pod
- **KUBE-NODEPORTS**: NodePort类型Service的规则链
- **KUBE-MARK-MASQ**: 标记需要进行SNAT的包
- **KUBE-POSTROUTING**: 执行SNAT操作

### 分析iptables规则

1. 查看所有Service相关规则
```bash
iptables-save | grep -E 'KUBE-SVC|KUBE-SEP'
```

2. 查看特定Service的规则
```bash
SERVICE_NAME="my-service"
SERVICE_NAMESPACE="default"
SERVICE_CLUSTER_IP=$(kubectl get svc $SERVICE_NAME -n $SERVICE_NAMESPACE -o jsonpath='{.spec.clusterIP}')
iptables-save | grep $SERVICE_CLUSTER_IP
```

3. 查看Service的负载均衡规则
```bash
# 首先找到Service对应的SVC链
SVC_CHAIN=$(iptables-save | grep $SERVICE_CLUSTER_IP | grep KUBE-SVC | head -1 | awk '{print $3}')
# 查看该链的规则
iptables -t nat -L $SVC_CHAIN -v --line-numbers
```

4. 检查是否存在REJECT规则
```bash
iptables -L -n | grep REJECT
```

5. 跟踪数据包路径
```bash
# 在节点上安装iptables-trace工具
apt-get install xtables-addons-common  # Debian/Ubuntu
# 或
yum install xtables-addons  # RHEL/CentOS

# 启用跟踪
iptables -t raw -A PREROUTING -p tcp --dport <service-port> -j TRACE
iptables -t raw -A OUTPUT -p tcp --dport <service-port> -j TRACE

# 查看跟踪日志
dmesg | grep TRACE
```

## IPVS模式排查

IPVS模式提供更好的性能，但排查方法与iptables不同。

1. 检查IPVS模式是否启用
```bash
kubectl get cm -n kube-system kube-proxy -o yaml | grep mode
```

2. 查看IPVS规则
```bash
ipvsadm -ln
```

3. 查看特定Service的IPVS规则
```bash
SERVICE_CLUSTER_IP=$(kubectl get svc $SERVICE_NAME -n $SERVICE_NAMESPACE -o jsonpath='{.spec.clusterIP}')
ipvsadm -ln | grep -A 10 $SERVICE_CLUSTER_IP
```

4. 检查IPVS连接状态
```bash
ipvsadm -lnc
```

5. 常见IPVS问题
   - 内核未加载ip_vs模块
   - IPVS调度算法配置不当
   - 连接超时设置不合理

## 连接跟踪问题

连接跟踪（conntrack）是Linux内核的一个功能，用于跟踪网络连接状态。在Kubernetes中，conntrack问题是服务网络故障的常见原因。

### 检查连接跟踪状态

1. 查看连接跟踪表大小和使用情况
```bash
cat /proc/sys/net/netfilter/nf_conntrack_count  # 当前使用数量
cat /proc/sys/net/netfilter/nf_conntrack_max    # 最大容量
```

2. 查看连接跟踪表详情
```bash
conntrack -L
```

3. 查看特定Service的连接跟踪
```bash
SERVICE_CLUSTER_IP=$(kubectl get svc $SERVICE_NAME -n $SERVICE_NAMESPACE -o jsonpath='{.spec.clusterIP}')
conntrack -L | grep $SERVICE_CLUSTER_IP
```

### 常见连接跟踪问题

1. **连接跟踪表溢出**
   - 症状：服务间歇性不可用，内核日志中有"nf_conntrack: table full, dropping packet"
   - 解决：增加nf_conntrack_max值，优化超时设置

2. **连接跟踪冲突**
   - 症状：同一个客户端访问同一个服务的多个Pod时出现连接问题
   - 原因：SNAT后源端口冲突导致conntrack表项冲突
   - 解决：使用`externalTrafficPolicy: Local`或增加源端口范围

3. **TIME_WAIT状态积累**
   - 症状：大量连接处于TIME_WAIT状态，占用连接跟踪表
   - 解决：启用tcp_tw_reuse，减少tcp_fin_timeout

## DNS深度排查

DNS问题是服务访问故障的常见原因，需要深入排查。

### CoreDNS/KubeDNS检查

1. 检查DNS Pod状态
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

2. 检查DNS配置
```bash
kubectl get cm -n kube-system coredns -o yaml
```

3. 检查DNS日志
```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```

4. 检查DNS解析性能
```bash
kubectl run -it --rm --restart=Never dns-test --image=busybox -- time nslookup kubernetes.default
```

### DNS故障排查步骤

1. **检查DNS服务本身**
   - CoreDNS/KubeDNS Pod是否正常运行
   - 配置是否正确
   - 资源是否充足

2. **检查Pod的DNS配置**
   - 查看`/etc/resolv.conf`内容
   ```bash
   kubectl exec -it <pod-name> -- cat /etc/resolv.conf
   ```
   - 确认nameserver指向正确的集群DNS服务IP

3. **检查DNS策略**
   - 查看Pod的dnsPolicy设置
   ```bash
   kubectl get pod <pod-name> -o yaml | grep dnsPolicy
   ```

4. **检查网络连通性**
   - 确认Pod可以连接到DNS服务的IP和端口
   ```bash
   kubectl exec -it <pod-name> -- nc -zv <dns-service-ip> 53
   ```

5. **使用dig或nslookup进行深入测试**
   ```bash
   kubectl exec -it <pod-name> -- nslookup -debug <service-name>.<namespace>.svc.cluster.local
   ```

## NetworkPolicy排查

NetworkPolicy是Kubernetes的网络隔离机制，可能会阻止服务间通信。

### 检查NetworkPolicy

1. 列出命名空间中的NetworkPolicy
```bash
kubectl get networkpolicy -n <namespace>
```

2. 查看NetworkPolicy详情
```bash
kubectl describe networkpolicy <policy-name> -n <namespace>
```

3. 分析NetworkPolicy规则
   - 检查podSelector是否匹配目标Pod
   - 检查ingress/egress规则是否允许所需流量
   - 注意默认拒绝策略的存在

### 常见NetworkPolicy问题

1. **过于严格的默认策略**
   - 症状：新部署的服务无法通信
   - 解决：检查是否有默认拒绝所有流量的策略，为新服务添加例外

2. **选择器匹配错误**
   - 症状：特定服务之间无法通信
   - 解决：检查NetworkPolicy的podSelector和namespaceSelector是否正确

3. **端口配置错误**
   - 症状：服务可以建立连接但应用层通信失败
   - 解决：确保NetworkPolicy允许所有必要的端口和协议

4. **CNI插件不支持NetworkPolicy**
   - 症状：NetworkPolicy配置正确但不生效
   - 解决：确认使用的CNI插件支持NetworkPolicy（如Calico、Cilium等）

## 节点级网络问题

有时服务网络问题源于节点级别的网络配置。

### 检查节点网络配置

1. 查看节点网络接口
```bash
ip addr
ip route
```

2. 检查节点防火墙规则
```bash
iptables -L -n
iptables -t nat -L -n
```

3. 检查系统网络参数
```bash
sysctl -a | grep net.ipv4.ip_forward
sysctl -a | grep net.bridge.bridge-nf-call-iptables
```

### 常见节点网络问题

1. **IP转发未启用**
   - 症状：跨节点Pod通信失败
   - 解决：确保`net.ipv4.ip_forward=1`

2. **桥接过滤未启用**
   - 症状：容器网络与主机网络通信问题
   - 解决：确保`net.bridge.bridge-nf-call-iptables=1`

3. **MTU不匹配**
   - 症状：大数据包传输失败，小数据包正常
   - 解决：统一集群中所有网络接口的MTU设置

4. **路由表问题**
   - 症状：特定节点上的Pod无法访问外部网络或其他节点
   - 解决：检查节点路由表配置

## CNI插件相关问题

不同的CNI插件实现Pod网络的方式不同，可能影响服务网络行为。

### 常见CNI插件排查

1. **Calico**
   ```bash
   # 检查Calico节点状态
   kubectl get pods -n kube-system -l k8s-app=calico-node
   
   # 检查BGP对等状态
   kubectl exec -n kube-system calico-node-xxxx -- calicoctl node status
   
   # 检查IP池
   kubectl exec -n kube-system calico-node-xxxx -- calicoctl get ippool -o wide
   ```

2. **Flannel**
   ```bash
   # 检查Flannel Pod
   kubectl get pods -n kube-system -l app=flannel
   
   # 检查Flannel配置
   kubectl get cm -n kube-system kube-flannel-cfg -o yaml
   ```

3. **Cilium**
   ```bash
   # 检查Cilium状态
   kubectl -n kube-system exec cilium-xxxx -- cilium status
   
   # 检查Cilium端点
   kubectl -n kube-system exec cilium-xxxx -- cilium endpoint list
   ```

### 常见CNI问题

1. **Pod CIDR冲突**
   - 症状：新节点上的Pod无法通信
   - 解决：检查节点的Pod CIDR分配是否有重叠

2. **CNI配置错误**
   - 症状：Pod网络完全不通
   - 解决：检查CNI配置文件（通常在/etc/cni/net.d/）

3. **Overlay网络问题**
   - 症状：跨节点Pod通信失败
   - 解决：检查底层网络是否允许封装协议（VXLAN、IPIP等）

4. **CNI与云提供商网络冲突**
   - 症状：LoadBalancer类型Service不工作
   - 解决：确保CNI插件与云提供商网络控制器兼容

## 高级调试工具

### tcpdump

捕获和分析网络流量：

```bash
# 在节点上捕获Service相关流量
NODE_NAME=$(kubectl get pod <pod-name> -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE_NAME -it --image=nicolaka/netshoot

# 在节点shell中执行
tcpdump -i any host <service-ip> and port <service-port> -nn
```

### netshoot容器

使用功能齐全的网络诊断容器：

```bash
# 在目标命名空间中运行netshoot
kubectl run --rm -it netshoot --image=nicolaka/netshoot -n <namespace>

# 在Pod中执行各种网络诊断命令
# 例如：
mtr <service-name>
dig +search +short <service-name>
curl -v <service-name>:<port>
```

### ksniff

捕获特定Pod的网络流量：

```bash
# 安装ksniff
kubectl krew install sniff

# 捕获Pod流量
kubectl sniff <pod-name> -n <namespace> -f "port <port>" -o capture.pcap
```

### kubeshark

分析Kubernetes集群中的API流量：

```bash
# 安装kubeshark
curl -Lo kubeshark https://github.com/kubeshark/kubeshark/releases/latest/download/kubeshark && chmod +x kubeshark

# 部署并启动kubeshark
./kubeshark tap
```

## 性能问题诊断

服务网络性能问题通常表现为高延迟或低吞吐量。

### 检查网络延迟

1. 使用ping测试基本连通性和延迟
```bash
kubectl exec -it <pod-name> -- ping -c 10 <service-name>
```

2. 使用netperf/iperf测试网络性能
```bash
# 在一个Pod中运行netperf服务器
kubectl exec -it <server-pod> -- netserver

# 在另一个Pod中运行netperf客户端
kubectl exec -it <client-pod> -- netperf -H <server-pod-ip> -t TCP_RR
```

### 检查CPU和内存使用

高负载可能影响网络性能：

```bash
# 检查节点资源使用情况
kubectl top nodes

# 检查Pod资源使用情况
kubectl top pods -n <namespace>
```

### 检查kube-proxy性能

kube-proxy处理大量规则时可能成为瓶颈：

```bash
# 检查iptables规则数量
iptables-save | wc -l

# 检查IPVS规则数量
ipvsadm -ln | wc -l
```

### 常见性能问题

1. **iptables规则过多**
   - 症状：服务创建和更新缓慢，CPU使用率高
   - 解决：考虑切换到IPVS模式或使用eBPF替代方案

2. **节点网络带宽饱和**
   - 症状：网络延迟增加，吞吐量下降
   - 解决：检查节点网络接口统计信息，考虑增加带宽或优化流量

3. **conntrack表性能问题**
   - 症状：高并发下连接建立缓慢
   - 解决：增加哈希表大小，调整超时设置

## 真实案例分析

### 案例1：NodePort服务跨节点访问失败

**现象**：
- 通过节点A的NodePort可以访问服务
- 通过节点B的NodePort无法访问同一服务

**排查步骤**：

1. 检查Service配置
```bash
kubectl get svc <service-name> -o yaml
# 确认externalTrafficPolicy设置为Cluster而非Local
```

2. 检查节点B上的iptables规则
```bash
# 在节点B上执行
iptables -L -n | grep <nodeport>
# 发现REJECT规则：
# REJECT tcp -- 0.0.0.0/0 0.0.0.0/0 /* <namespace>/<service>:http has no endpoints */
```

3. 检查Endpoints
```bash
kubectl get endpoints <service-name>
# 确认Endpoints存在且有可用地址
```

4. 检查kube-proxy日志
```bash
kubectl logs -n kube-system <kube-proxy-pod-on-node-B>
# 发现kube-proxy未正确同步Endpoints信息
```

**根本原因**：
节点B上的kube-proxy与API服务器之间的通信问题，导致未能正确获取Endpoints更新。

**解决方案**：
1. 重启节点B上的kube-proxy
2. 检查并修复节点B与API服务器的网络连接
3. 删除错误的iptables规则：`iptables -D KUBE-EXTERNAL-SERVICES 1`

### 案例2：服务间歇性不可用

**现象**：
- 服务大部分时间正常
- 在高负载时出现连接超时
- 重试几秒后又恢复正常

**排查步骤**：

1. 检查系统日志
```bash
dmesg | grep conntrack
# 发现：nf_conntrack: table full, dropping packet
```

2. 检查连接跟踪表使用情况
```bash
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max
# 发现count接近max
```

3. 分析连接模式
```bash
conntrack -S
# 发现大量TIME_WAIT状态连接
```

**根本原因**：
高并发下连接跟踪表溢出，导致新连接被丢弃。

**解决方案**：
1. 增加连接跟踪表大小：
```bash
sysctl -w net.netfilter.nf_conntrack_max=2000000
sysctl -w net.netfilter.nf_conntrack_buckets=500000
```

2. 优化TCP参数：
```bash
sysctl -w net.ipv4.tcp_fin_timeout=30
sysctl -w net.ipv4.tcp_tw_reuse=1
```

3. 持久化配置到/etc/sysctl.conf

### 案例3：DNS解析缓慢

**现象**：
- 服务首次访问延迟高（5秒以上）
- 后续访问正常
- 问题在一段时间不活动后再次出现

**排查步骤**：

1. 测试DNS解析时间
```bash
time nslookup <service-name>.<namespace>.svc.cluster.local
# 发现首次解析需要5秒以上
```

2. 检查CoreDNS配置
```bash
kubectl get cm -n kube-system coredns -o yaml
# 发现没有启用缓存或缓存时间短
```

3. 检查CoreDNS Pod资源使用情况
```bash
kubectl top pods -n kube-system -l k8s-app=kube-dns
# 发现CPU使用率高
```

**根本原因**：
CoreDNS缓存配置不当，每次解析都需要完整查询链，且资源不足。

**解决方案**：
1. 优化CoreDNS配置，增加缓存：
```yaml
cache {
  success 10000
  denial 1000
  prefetch 10 10%
}
```

2. 增加CoreDNS资源限制
3. 考虑部署NodeLocal DNSCache

## 总结

Kubernetes服务网络故障排查是一个复杂的过程，需要深入理解多个组件的工作原理和交互方式。本指南提供了系统化的排查方法和工具，帮助您解决从简单到复杂的各类服务网络问题。

记住以下关键点：
1. 从上到下系统化排查，从应用层到网络层
2. 利用适当的工具收集足够的诊断信息
3. 理解组件间的交互和依赖关系
4. 建立基准，了解正常状态下的系统行为
5. 保持耐心，网络问题有时需要多角度分析 