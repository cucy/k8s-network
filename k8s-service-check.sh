#!/bin/bash
#
# Kubernetes服务流量排查脚本
# 用途：快速诊断K8s集群中指定服务是否正常接收流量，并指出流量阻塞或异常的原因
# 作者：AI助手
# 版本：1.0

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
TEMP_POD_NAME="k8s-service-check-temp"
TEMP_POD_IMAGE="nicolaka/netshoot:latest"
ISSUES_FOUND=0
DIAGNOSTIC_REPORT=""

# 显示脚本使用方法
function show_usage() {
    echo -e "${BLUE}用法:${NC}"
    echo "  $0 -s <service_name> -n <namespace> [-p <protocol>] [-o <port>] [-i <ingress_host>] [-h <health_check_path>]"
    echo ""
    echo -e "${BLUE}必选参数:${NC}"
    echo "  -s, --service     服务名称"
    echo "  -n, --namespace   命名空间"
    echo ""
    echo -e "${BLUE}可选参数:${NC}"
    echo "  -p, --protocol    协议类型 (http|https|tcp), 默认: http"
    echo "  -o, --port        服务端口, 默认: 80"
    echo "  -i, --ingress     Ingress主机名 (如果通过Ingress暴露)"
    echo "  -h, --health      健康检查路径 (HTTP/HTTPS服务), 默认: /"
    echo "  --help            显示此帮助信息并退出"
    echo ""
    echo -e "${BLUE}示例:${NC}"
    echo "  $0 -s nginx -n default"
    echo "  $0 -s my-api -n api-system -p https -o 443 -h /healthz"
    echo "  $0 -s web-app -n frontend -i webapp.example.com"
    exit 1
}

# 检查依赖工具
function check_dependencies() {
    echo -e "${BLUE}[检查] 检查必要的依赖工具...${NC}"
    
    local missing_deps=0
    for cmd in kubectl curl jq nc dig; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[错误] 缺少依赖: $cmd${NC}"
            missing_deps=1
        fi
    done
    
    if [ $missing_deps -eq 1 ]; then
        echo -e "${RED}[错误] 请安装缺少的依赖后再运行此脚本${NC}"
        exit 1
    fi
    
    # 检查kubectl是否已配置
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}[错误] kubectl未配置或无法连接到Kubernetes集群${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}[成功] 所有依赖工具已就绪${NC}"
}

# 解析命令行参数
function parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -s|--service) SERVICE="$2"; shift ;;
            -n|--namespace) NAMESPACE="$2"; shift ;;
            -p|--protocol) PROTOCOL="$2"; shift ;;
            -o|--port) PORT="$2"; shift ;;
            -i|--ingress) INGRESS_HOST="$2"; shift ;;
            -h|--health) HEALTH_PATH="$2"; shift ;;
            --help) show_usage ;;
            *) echo -e "${RED}[错误] 未知参数: $1${NC}" >&2; show_usage ;;
        esac
        shift
    done

    # 验证必要参数
    if [ -z "$SERVICE" ] || [ -z "$NAMESPACE" ]; then
        echo -e "${RED}[错误] 服务名称和命名空间为必填参数${NC}"
        show_usage
    fi

    # 设置默认值
    PROTOCOL=${PROTOCOL:-http}
    PORT=${PORT:-80}
    HEALTH_PATH=${HEALTH_PATH:-/}
    
    # 验证协议类型
    if [[ ! "$PROTOCOL" =~ ^(http|https|tcp)$ ]]; then
        echo -e "${RED}[错误] 不支持的协议类型: $PROTOCOL. 支持的类型: http, https, tcp${NC}"
        exit 1
    fi
}

# 记录诊断信息
function add_diagnostic {
    DIAGNOSTIC_REPORT+="$1\n"
}

# 记录问题
function add_issue {
    ISSUES_FOUND=$((ISSUES_FOUND+1))
    echo -e "${RED}[问题 #$ISSUES_FOUND] $1${NC}"
    add_diagnostic "[问题 #$ISSUES_FOUND] $1"
}

# 1. Kubernetes对象检查
function check_k8s_objects() {
    echo -e "${BLUE}[检查] 检查Kubernetes对象...${NC}"
    
    # 1.1 检查Service是否存在
    echo -e "${BLUE}[检查] 检查Service $SERVICE 是否存在...${NC}"
    if ! kubectl get service $SERVICE -n $NAMESPACE &> /dev/null; then
        add_issue "服务 $SERVICE 在命名空间 $NAMESPACE 中不存在"
        add_diagnostic "$(kubectl get services -n $NAMESPACE 2>&1)"
        return 1
    fi
    
    # 获取Service详情
    SERVICE_JSON=$(kubectl get service $SERVICE -n $NAMESPACE -o json)
    
    # 1.2 检查Service类型
    SERVICE_TYPE=$(echo $SERVICE_JSON | jq -r '.spec.type')
    echo -e "${BLUE}[检查] 服务类型: $SERVICE_TYPE${NC}"
    add_diagnostic "服务类型: $SERVICE_TYPE"
    
    # 1.3 检查Service选择器
    SERVICE_SELECTOR=$(echo $SERVICE_JSON | jq -r '.spec.selector | to_entries | map("\(.key)=\(.value)") | join(",")')
    if [ "$SERVICE_SELECTOR" == "" ] || [ "$SERVICE_SELECTOR" == "null" ]; then
        echo -e "${YELLOW}[警告] 服务没有定义选择器，这可能是一个无头服务或外部服务${NC}"
        add_diagnostic "服务没有定义选择器，这可能是一个无头服务或外部服务"
    else
        echo -e "${BLUE}[检查] 服务选择器: $SERVICE_SELECTOR${NC}"
        add_diagnostic "服务选择器: $SERVICE_SELECTOR"
        
        # 1.4 检查是否有匹配的Pod
        POD_COUNT=$(kubectl get pods -n $NAMESPACE -l $SERVICE_SELECTOR -o json | jq '.items | length')
        if [ "$POD_COUNT" -eq 0 ]; then
            add_issue "没有找到与服务选择器 ($SERVICE_SELECTOR) 匹配的Pod"
            return 1
        fi
        echo -e "${BLUE}[检查] 找到 $POD_COUNT 个匹配的Pod${NC}"
        add_diagnostic "找到 $POD_COUNT 个匹配的Pod"
        
        # 1.5 检查Pod状态
        RUNNING_PODS=$(kubectl get pods -n $NAMESPACE -l $SERVICE_SELECTOR -o json | jq '[.items[] | select(.status.phase=="Running")] | length')
        if [ "$RUNNING_PODS" -eq 0 ]; then
            add_issue "没有处于Running状态的Pod"
            add_diagnostic "$(kubectl get pods -n $NAMESPACE -l $SERVICE_SELECTOR 2>&1)"
            return 1
        fi
        echo -e "${BLUE}[检查] $RUNNING_PODS 个Pod处于Running状态${NC}"
        
        # 1.6 检查Pod就绪状态
        READY_PODS=$(kubectl get pods -n $NAMESPACE -l $SERVICE_SELECTOR -o json | \
                     jq '[.items[] | select(.status.containerStatuses != null) | 
                         select([.status.containerStatuses[] | .ready] | all)] | length')
        if [ "$READY_PODS" -eq 0 ]; then
            add_issue "没有就绪的Pod (所有容器都Ready)"
            add_diagnostic "$(kubectl get pods -n $NAMESPACE -l $SERVICE_SELECTOR 2>&1)"
            return 1
        fi
        echo -e "${GREEN}[成功] $READY_PODS 个Pod已就绪${NC}"
    fi
    
    # 1.7 检查Endpoints
    echo -e "${BLUE}[检查] 检查服务Endpoints...${NC}"
    ENDPOINTS_JSON=$(kubectl get endpoints $SERVICE -n $NAMESPACE -o json 2>/dev/null)
    if [ $? -ne 0 ]; then
        add_issue "无法获取服务的Endpoints"
        return 1
    fi
    
    ENDPOINTS_COUNT=$(echo $ENDPOINTS_JSON | jq '.subsets | length')
    if [ "$ENDPOINTS_COUNT" -eq 0 ] || [ "$ENDPOINTS_COUNT" == "null" ]; then
        add_issue "服务没有可用的Endpoints"
        add_diagnostic "$(kubectl describe endpoints $SERVICE -n $NAMESPACE 2>&1)"
        return 1
    fi
    
    ADDRESSES_COUNT=$(echo $ENDPOINTS_JSON | jq '.subsets[0].addresses | length')
    if [ "$ADDRESSES_COUNT" -eq 0 ] || [ "$ADDRESSES_COUNT" == "null" ]; then
        add_issue "服务Endpoints没有可用的地址"
        add_diagnostic "$(kubectl describe endpoints $SERVICE -n $NAMESPACE 2>&1)"
        return 1
    fi
    
    echo -e "${GREEN}[成功] 服务有 $ADDRESSES_COUNT 个可用的Endpoint地址${NC}"
    add_diagnostic "服务有 $ADDRESSES_COUNT 个可用的Endpoint地址"
    
    # 1.8 检查NetworkPolicy
    echo -e "${BLUE}[检查] 检查可能阻止流量的NetworkPolicy...${NC}"
    NP_COUNT=$(kubectl get networkpolicy -n $NAMESPACE -o json 2>/dev/null | jq '.items | length')
    if [ $? -eq 0 ] && [ "$NP_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}[警告] 在命名空间 $NAMESPACE 中发现 $NP_COUNT 个NetworkPolicy，可能会影响流量${NC}"
        add_diagnostic "在命名空间 $NAMESPACE 中发现 $NP_COUNT 个NetworkPolicy，可能会影响流量"
        add_diagnostic "$(kubectl get networkpolicy -n $NAMESPACE -o wide 2>&1)"
    else
        echo -e "${BLUE}[检查] 未发现NetworkPolicy${NC}"
    fi
    
    # 1.9 检查Ingress (如果提供了Ingress主机名)
    if [ ! -z "$INGRESS_HOST" ]; then
        echo -e "${BLUE}[检查] 检查Ingress配置...${NC}"
        INGRESS_JSON=$(kubectl get ingress -n $NAMESPACE -o json | \
                       jq ".items[] | select(.spec.rules[].host==\"$INGRESS_HOST\")")
        
        if [ -z "$INGRESS_JSON" ] || [ "$INGRESS_JSON" == "" ]; then
            add_issue "未找到主机名为 $INGRESS_HOST 的Ingress"
            add_diagnostic "$(kubectl get ingress -n $NAMESPACE 2>&1)"
            return 1
        fi
        
        # 检查Ingress是否指向正确的服务
        INGRESS_SERVICE=$(echo $INGRESS_JSON | jq -r '.spec.rules[0].http.paths[] | select(.backend.service.name=="'$SERVICE'") | .backend.service.name')
        if [ -z "$INGRESS_SERVICE" ] || [ "$INGRESS_SERVICE" != "$SERVICE" ]; then
            add_issue "Ingress不指向服务 $SERVICE"
            add_diagnostic "$(echo $INGRESS_JSON | jq 2>&1)"
            return 1
        fi
        
        echo -e "${GREEN}[成功] Ingress配置正确指向服务 $SERVICE${NC}"
        add_diagnostic "Ingress配置正确指向服务 $SERVICE"
    fi
    
    return 0
}

# 2. 创建临时诊断Pod
function create_temp_pod() {
    echo -e "${BLUE}[检查] 创建临时诊断Pod...${NC}"
    
    # 检查是否已存在
    if kubectl get pod $TEMP_POD_NAME -n $NAMESPACE &> /dev/null; then
        echo -e "${YELLOW}[警告] 临时Pod已存在，将删除并重新创建${NC}"
        kubectl delete pod $TEMP_POD_NAME -n $NAMESPACE --grace-period=0 --force &> /dev/null
        sleep 2
    fi
    
    # 创建临时Pod
    cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $TEMP_POD_NAME
  namespace: $NAMESPACE
spec:
  containers:
  - name: netshoot
    image: $TEMP_POD_IMAGE
    command:
    - sleep
    - "3600"
  restartPolicy: Never
EOF
    
    # 等待Pod就绪
    echo -e "${BLUE}[检查] 等待临时Pod就绪...${NC}"
    RETRY=0
    MAX_RETRY=30
    while [ $RETRY -lt $MAX_RETRY ]; do
        POD_STATUS=$(kubectl get pod $TEMP_POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$POD_STATUS" == "Running" ]; then
            echo -e "${GREEN}[成功] 临时Pod已就绪${NC}"
            return 0
        fi
        RETRY=$((RETRY+1))
        sleep 2
    done
    
    add_issue "临时诊断Pod创建失败或未就绪"
    add_diagnostic "$(kubectl describe pod $TEMP_POD_NAME -n $NAMESPACE 2>&1)"
    return 1
}

# 3. 网络连通性检查
function check_network_connectivity() {
    echo -e "${BLUE}[检查] 检查网络连通性...${NC}"
    
    # 3.1 获取Service ClusterIP
    CLUSTER_IP=$(kubectl get service $SERVICE -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')
    if [ "$CLUSTER_IP" == "None" ]; then
        echo -e "${YELLOW}[警告] 服务是无头服务 (ClusterIP=None)，跳过ClusterIP检查${NC}"
        add_diagnostic "服务是无头服务 (ClusterIP=None)，跳过ClusterIP检查"
    else
        echo -e "${BLUE}[检查] 服务ClusterIP: $CLUSTER_IP${NC}"
        add_diagnostic "服务ClusterIP: $CLUSTER_IP"
        
        # 3.2 检查DNS解析
        echo -e "${BLUE}[检查] 检查DNS解析...${NC}"
        DNS_RESULT=$(kubectl exec -n $NAMESPACE $TEMP_POD_NAME -- nslookup $SERVICE 2>&1)
        if ! echo "$DNS_RESULT" | grep -q "$CLUSTER_IP"; then
            add_issue "DNS解析失败: 无法将服务名 $SERVICE 解析为ClusterIP $CLUSTER_IP"
            add_diagnostic "$DNS_RESULT"
        else
            echo -e "${GREEN}[成功] DNS解析正常${NC}"
            add_diagnostic "DNS解析正常: $SERVICE -> $CLUSTER_IP"
        fi
        
        # 3.3 检查端口连通性
        echo -e "${BLUE}[检查] 检查服务端口连通性...${NC}"
        CONN_RESULT=$(kubectl exec -n $NAMESPACE $TEMP_POD_NAME -- timeout 5 nc -zv $CLUSTER_IP $PORT 2>&1)
        if [ $? -ne 0 ]; then
            add_issue "无法连接到服务 $SERVICE 的端口 $PORT"
            add_diagnostic "$CONN_RESULT"
        else
            echo -e "${GREEN}[成功] 可以连接到服务端口${NC}"
            add_diagnostic "可以连接到服务端口: $CLUSTER_IP:$PORT"
        fi
    fi
    
    # 3.4 检查Pod IP连通性
    echo -e "${BLUE}[检查] 检查Pod IP连通性...${NC}"
    POD_IPS=$(kubectl get endpoints $SERVICE -n $NAMESPACE -o jsonpath='{.subsets[0].addresses[*].ip}')
    POD_PORT=$(kubectl get endpoints $SERVICE -n $NAMESPACE -o jsonpath='{.subsets[0].ports[0].port}')
    
    if [ -z "$POD_IPS" ]; then
        add_issue "无法获取Pod IP地址"
        return 1
    fi
    
    for POD_IP in $POD_IPS; do
        echo -e "${BLUE}[检查] 检查Pod IP: $POD_IP:$POD_PORT${NC}"
        CONN_RESULT=$(kubectl exec -n $NAMESPACE $TEMP_POD_NAME -- timeout 5 nc -zv $POD_IP $POD_PORT 2>&1)
        if [ $? -ne 0 ]; then
            add_issue "无法连接到Pod IP $POD_IP 的端口 $POD_PORT"
            add_diagnostic "$CONN_RESULT"
        else
            echo -e "${GREEN}[成功] 可以连接到Pod IP $POD_IP:$POD_PORT${NC}"
            add_diagnostic "可以连接到Pod IP: $POD_IP:$POD_PORT"
        fi
    done
    
    # 3.5 检查Ingress连通性 (如果提供了Ingress主机名)
    if [ ! -z "$INGRESS_HOST" ]; then
        echo -e "${BLUE}[检查] 检查Ingress连通性...${NC}"
        
        # 从集群内部检查
        CONN_RESULT=$(kubectl exec -n $NAMESPACE $TEMP_POD_NAME -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://$INGRESS_HOST 2>&1)
        if [[ ! "$CONN_RESULT" =~ ^(200|301|302|307|308)$ ]]; then
            add_issue "从集群内部无法通过Ingress主机名访问服务: HTTP状态码 $CONN_RESULT"
        else
            echo -e "${GREEN}[成功] 从集群内部可以通过Ingress访问服务${NC}"
            add_diagnostic "从集群内部可以通过Ingress访问服务: HTTP状态码 $CONN_RESULT"
        fi
        
        # 提示用户从外部检查
        echo -e "${YELLOW}[提示] 请从集群外部执行以下命令验证Ingress连通性:${NC}"
        echo -e "  curl -v http://$INGRESS_HOST"
    fi
    
    return 0
}

# 4. 应用层检查
function check_application() {
    echo -e "${BLUE}[检查] 执行应用层检查...${NC}"
    
    # 获取Service ClusterIP
    CLUSTER_IP=$(kubectl get service $SERVICE -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')
    
    # 4.1 HTTP/HTTPS检查
    if [ "$PROTOCOL" == "http" ] || [ "$PROTOCOL" == "https" ]; then
        echo -e "${BLUE}[检查] 执行HTTP健康检查...${NC}"
        
        # 构建URL
        if [ "$CLUSTER_IP" == "None" ]; then
            # 无头服务，使用服务名
            URL="${PROTOCOL}://${SERVICE}.${NAMESPACE}.svc.cluster.local:${PORT}${HEALTH_PATH}"
        else
            # 使用ClusterIP
            URL="${PROTOCOL}://${CLUSTER_IP}:${PORT}${HEALTH_PATH}"
        fi
        
        # 执行HTTP请求
        echo -e "${BLUE}[检查] 请求URL: $URL${NC}"
        HTTP_RESULT=$(kubectl exec -n $NAMESPACE $TEMP_POD_NAME -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 $URL 2>&1)
        
        if [[ ! "$HTTP_RESULT" =~ ^(200|301|302|307|308)$ ]]; then
            add_issue "HTTP健康检查失败: 状态码 $HTTP_RESULT"
            
            # 获取更多详细信息
            DETAILED_RESULT=$(kubectl exec -n $NAMESPACE $TEMP_POD_NAME -- curl -v --connect-timeout 5 $URL 2>&1)
            add_diagnostic "HTTP请求详情:\n$DETAILED_RESULT"
        else
            echo -e "${GREEN}[成功] HTTP健康检查通过: 状态码 $HTTP_RESULT${NC}"
            add_diagnostic "HTTP健康检查通过: 状态码 $HTTP_RESULT"
            
            # 获取响应头信息
            HEADERS=$(kubectl exec -n $NAMESPACE $TEMP_POD_NAME -- curl -s -I --connect-timeout 5 $URL 2>&1)
            add_diagnostic "HTTP响应头:\n$HEADERS"
        fi
    fi
    
    # 4.2 TCP检查
    if [ "$PROTOCOL" == "tcp" ]; then
        echo -e "${BLUE}[检查] 执行TCP连接测试...${NC}"
        
        if [ "$CLUSTER_IP" == "None" ]; then
            # 无头服务，使用服务名
            HOST="${SERVICE}.${NAMESPACE}.svc.cluster.local"
        else
            # 使用ClusterIP
            HOST="$CLUSTER_IP"
        fi
        
        # 执行TCP连接测试
        TCP_RESULT=$(kubectl exec -n $NAMESPACE $TEMP_POD_NAME -- timeout 5 nc -zv $HOST $PORT 2>&1)
        if [ $? -ne 0 ]; then
            add_issue "TCP连接测试失败"
            add_diagnostic "$TCP_RESULT"
        else
            echo -e "${GREEN}[成功] TCP连接测试通过${NC}"
            add_diagnostic "TCP连接测试通过: $HOST:$PORT"
        fi
    fi
    
    return 0
}

# 5. 清理临时资源
function cleanup() {
    echo -e "${BLUE}[清理] 删除临时诊断Pod...${NC}"
    kubectl delete pod $TEMP_POD_NAME -n $NAMESPACE --grace-period=0 --force &> /dev/null
}

# 6. 生成最终报告
function generate_report() {
    echo -e "\n${BLUE}==========================================${NC}"
    echo -e "${BLUE}   诊断报告摘要   ${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    if [ $ISSUES_FOUND -eq 0 ]; then
        echo -e "${GREEN}[结论] 未发现问题! 服务 $SERVICE 在命名空间 $NAMESPACE 中工作正常${NC}"
    else
        echo -e "${RED}[结论] 发现 $ISSUES_FOUND 个问题${NC}"
        echo -e "\n${YELLOW}问题摘要:${NC}"
        echo -e "$DIAGNOSTIC_REPORT" | grep "\[问题"
    fi
    
    echo -e "\n${BLUE}是否需要查看完整诊断报告? (y/n)${NC}"
    read -r SHOW_REPORT
    if [[ "$SHOW_REPORT" =~ ^[Yy]$ ]]; then
        echo -e "\n${BLUE}==========================================${NC}"
        echo -e "${BLUE}   完整诊断报告   ${NC}"
        echo -e "${BLUE}==========================================${NC}"
        echo -e "$DIAGNOSTIC_REPORT"
    fi
    
    echo -e "\n${BLUE}==========================================${NC}"
    echo -e "${YELLOW}建议的后续步骤:${NC}"
    
    if [ $ISSUES_FOUND -gt 0 ]; then
        echo -e "1. 检查Pod日志: kubectl logs -n $NAMESPACE <pod-name>"
        echo -e "2. 查看Pod详情: kubectl describe pod -n $NAMESPACE <pod-name>"
        echo -e "3. 检查Service详情: kubectl describe service $SERVICE -n $NAMESPACE"
        echo -e "4. 检查Endpoints: kubectl describe endpoints $SERVICE -n $NAMESPACE"
        
        if [ ! -z "$INGRESS_HOST" ]; then
            echo -e "5. 检查Ingress详情: kubectl describe ingress -n $NAMESPACE"
        fi
        
        echo -e "\n${YELLOW}高级排查工具:${NC}"
        echo -e "1. 使用tcpdump捕获网络流量: kubectl debug node/<node-name> -it --image=nicolaka/netshoot -- tcpdump -i any port $PORT"
        echo -e "2. 使用ksniff捕获Pod流量: kubectl sniff <pod-name> -n $NAMESPACE -f \"port $PORT\""
        echo -e "3. 检查kube-proxy日志: kubectl logs -n kube-system -l k8s-app=kube-proxy"
        echo -e "4. 检查节点上的iptables规则: kubectl debug node/<node-name> -it --image=nicolaka/netshoot -- iptables-save | grep $SERVICE"
    else
        echo -e "服务工作正常，无需进一步排查。"
    fi
}

# 主函数
function main() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}   Kubernetes服务流量排查脚本   ${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    check_dependencies
    parse_args "$@"
    
    echo -e "${BLUE}[信息] 开始检查服务 ${SERVICE} 在命名空间 ${NAMESPACE}${NC}"
    echo -e "${BLUE}[信息] 协议: ${PROTOCOL}, 端口: ${PORT}${NC}"
    if [ ! -z "$INGRESS_HOST" ]; then
        echo -e "${BLUE}[信息] Ingress主机名: ${INGRESS_HOST}${NC}"
    fi
    
    # 1. 检查Kubernetes对象
    check_k8s_objects
    
    # 2. 创建临时诊断Pod
    create_temp_pod
    if [ $? -eq 0 ]; then
        # 3. 检查网络连通性
        check_network_connectivity
        
        # 4. 应用层检查
        check_application
        
        # 5. 清理临时资源
        cleanup
    fi
    
    # 6. 生成最终报告
    generate_report
}

# 捕获Ctrl+C信号，确保清理临时资源
trap cleanup EXIT INT TERM

# 执行主函数
main "$@" 