# Kubernetes服务流量排查工具

这个脚本用于快速诊断Kubernetes集群中服务的流量问题，帮助SRE和运维人员在用户反馈服务无法访问或访问异常时进行系统化排查。

## 功能特点

- **全面检查**: 从Kubernetes对象、网络连通性到应用层响应进行全方位检查
- **自动诊断**: 自动识别常见问题并提供清晰的错误提示
- **详细报告**: 生成完整的诊断报告，包括问题摘要和建议的后续步骤
- **临时诊断Pod**: 自动创建和清理临时诊断Pod，用于集群内部测试
- **支持多种协议**: 支持HTTP、HTTPS和TCP服务的检查

## 前提条件

- 已安装并配置kubectl，可连接到目标Kubernetes集群
- 具有以下命令行工具：
  - curl: 用于HTTP/HTTPS请求
  - jq: 用于解析JSON
  - nc (netcat): 用于TCP连接测试
  - dig: 用于DNS解析测试
- 具有足够的权限在目标命名空间中创建和删除Pod，以及获取Service、Endpoints、Pod等资源信息

## 使用方法

### 基本用法

```bash
./k8s-service-check.sh -s <service_name> -n <namespace>
```

### 完整参数

```bash
./k8s-service-check.sh -s <service_name> -n <namespace> [-p <protocol>] [-o <port>] [-i <ingress_host>] [-h <health_check_path>]
```

- `-s, --service`: 服务名称（必填）
- `-n, --namespace`: 命名空间（必填）
- `-p, --protocol`: 协议类型 (http|https|tcp)，默认: http
- `-o, --port`: 服务端口，默认: 80
- `-i, --ingress`: Ingress主机名（如果通过Ingress暴露）
- `-h, --health`: 健康检查路径（HTTP/HTTPS服务），默认: /

### 示例

检查默认命名空间中的nginx服务（HTTP协议，端口80）:
```bash
./k8s-service-check.sh -s nginx -n default
```

检查API服务（HTTPS协议，端口443，健康检查路径/healthz）:
```bash
./k8s-service-check.sh -s my-api -n api-system -p https -o 443 -h /healthz
```

检查通过Ingress暴露的Web应用:
```bash
./k8s-service-check.sh -s web-app -n frontend -i webapp.example.com
```

## 检查内容

脚本会按照以下顺序进行检查：

### 1. Kubernetes对象检查
- 服务是否存在
- 服务类型是否符合预期
- 服务选择器是否匹配到Pod
- Pod是否处于Running状态
- Pod是否就绪（Ready）
- 服务是否有可用的Endpoints
- 是否存在可能阻止流量的NetworkPolicy
- Ingress配置是否正确（如果提供了Ingress主机名）

### 2. 网络连通性检查
- DNS解析：服务名是否能解析到正确的ClusterIP
- 服务连通性：是否能连接到服务的ClusterIP和端口
- Pod连通性：是否能直接连接到后端Pod的IP和端口
- Ingress连通性：是否能通过Ingress主机名访问服务（如果适用）

### 3. 应用层检查
- 对于HTTP/HTTPS服务：健康检查路径是否返回成功状态码
- 对于TCP服务：是否能建立TCP连接

## 常见问题排查

### 服务无法访问的常见原因

1. **服务配置问题**
   - 服务选择器与Pod标签不匹配
   - 服务端口配置错误
   - 服务类型不符合预期（如需要NodePort但配置为ClusterIP）

2. **Pod问题**
   - Pod未处于Running状态
   - Pod未通过就绪检查（Readiness Probe）
   - 容器内应用未正确监听端口

3. **网络问题**
   - NetworkPolicy阻止了流量
   - kube-proxy配置错误或未正常工作
   - 集群网络插件（CNI）问题
   - 节点防火墙规则阻止了流量

4. **Ingress问题**
   - Ingress配置错误
   - Ingress Controller未正常工作
   - TLS证书问题（HTTPS）
   - DNS解析问题

### 高级排查技巧

1. **检查Pod日志**
   ```bash
   kubectl logs -n <namespace> <pod-name>
   ```

2. **检查Pod内部网络配置**
   ```bash
   kubectl exec -it -n <namespace> <pod-name> -- ip addr
   kubectl exec -it -n <namespace> <pod-name> -- netstat -tuln
   ```

3. **检查kube-proxy日志**
   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-proxy
   ```

4. **检查节点上的iptables规则**
   ```bash
   kubectl debug node/<node-name> -it --image=nicolaka/netshoot -- iptables-save | grep <service-name>
   ```

5. **使用tcpdump捕获网络流量**
   ```bash
   kubectl debug node/<node-name> -it --image=nicolaka/netshoot -- tcpdump -i any port <port>
   ```

6. **检查CoreDNS/KubeDNS日志**
   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns
   ```

## 权限要求

运行此脚本的用户需要具有以下Kubernetes权限：

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: service-troubleshooter
  namespace: <target-namespace>
rules:
- apiGroups: [""]
  resources: ["services", "endpoints", "pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["create", "delete"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies", "ingresses"]
  verbs: ["get", "list", "watch"]
```

## 注意事项

- 脚本会在目标命名空间中创建一个临时Pod，完成检查后会自动删除
- 如果脚本执行中断，可能需要手动删除临时Pod: `kubectl delete pod k8s-service-check-temp -n <namespace>`
- 某些检查可能需要集群管理员权限，特别是与NetworkPolicy和节点级别检查相关的操作
- 脚本默认使用`nicolaka/netshoot`镜像作为诊断容器，确保您的环境可以拉取此镜像

## 常见陷阱和最佳实践

1. **Pod就绪但服务不可访问**
   - 检查Pod是否正确暴露了服务端口
   - 确认应用在容器内正确监听在0.0.0.0而不是127.0.0.1

2. **服务有Endpoints但无法连接**
   - 检查kube-proxy是否正常工作
   - 检查是否有NetworkPolicy阻止了流量
   - 检查节点上的iptables规则是否正确

3. **Ingress配置看似正确但无法访问**
   - 确认Ingress Controller是否正常运行
   - 检查TLS证书配置（如果使用HTTPS）
   - 验证DNS解析是否正确指向Ingress Controller

4. **服务间歇性不可用**
   - 检查Pod资源限制是否合理
   - 检查节点资源使用情况
   - 考虑连接跟踪表（conntrack）是否溢出

5. **最佳实践**
   - 为所有服务配置适当的就绪检查（Readiness Probe）和存活检查（Liveness Probe）
   - 使用明确的服务和Pod标签，避免选择器冲突
   - 为关键服务配置反亲和性规则，避免单点故障
   - 记录服务依赖关系，便于系统性排查
   - 实施监控和告警，提前发现潜在问题

## 贡献

欢迎提交问题报告、功能请求和代码贡献。

## 许可

MIT License 