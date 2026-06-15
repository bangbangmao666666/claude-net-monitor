#!/usr/bin/env bash
# Clash (mihomo) API 操作模块：经 unix socket 控制，在候选节点（关键词可配）间切换。
# 设计为被 monitor.sh source；也可单独 `source clash.sh` 后手动调用各函数测试。
# 仅定义函数与常量，无主流程，source 安全。
set -u

CLASH_SOCK="${CLASH_SOCK:-/var/tmp/verge/verge-mihomo.sock}"
# 自动切换候选节点的地区关键词（多个用 | 分隔）：名字含任一关键词的节点都是候选。
# 例：改成 "日本|香港" 把香港也纳入；可用环境变量 NODE_KEYWORDS 覆盖。
NODE_KEYWORDS="${NODE_KEYWORDS:-日本}"
DELAY_TEST_URL="${DELAY_TEST_URL:-https://www.gstatic.com/generate_204}"
DELAY_TEST_TIMEOUT="${DELAY_TEST_TIMEOUT:-1500}"
PY=/usr/bin/python3

# 经 unix socket 调 Clash API（返回响应体）。用法：clash_api GET /proxies [body]
clash_api() {
  local method="$1" path="$2" body="${3:-}"
  [[ -S "$CLASH_SOCK" ]] || return 1
  if [[ -n "$body" ]]; then
    curl -s --max-time 5 --unix-socket "$CLASH_SOCK" \
      -X "$method" -H 'Content-Type: application/json' -d "$body" \
      "http://localhost${path}" 2>/dev/null
  else
    curl -s --max-time 5 --unix-socket "$CLASH_SOCK" \
      -X "$method" "http://localhost${path}" 2>/dev/null
  fi
}

# URL 编码（节点名含中文与特殊字符）
clash_urlenc() {
  "$PY" -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

# 节点名是否匹配 NODE_KEYWORDS 中任一关键词（| 分隔，子串包含，非正则）
_node_matches() {
  local name="$1" kw old_ifs="$IFS"
  IFS='|'
  for kw in $NODE_KEYWORDS; do
    if [[ -n "$kw" && "$name" == *"$kw"* ]]; then IFS="$old_ifs"; return 0; fi
  done
  IFS="$old_ifs"
  return 1
}

# 按运行模式返回应操作的组：global->GLOBAL，其它->Proxy
clash_target_group() {
  local mode
  mode=$(clash_api GET /configs | "$PY" -c 'import sys,json
try: print(json.load(sys.stdin).get("mode",""))
except Exception: print("")' 2>/dev/null)
  if [[ "$mode" == "global" ]]; then echo "GLOBAL"; else echo "Proxy"; fi
}

# 列出所有候选节点（每行一个）：名字含 NODE_KEYWORDS 任一关键词，排除组类型
clash_candidate_nodes() {
  clash_api GET /proxies | NODE_KEYWORDS="$NODE_KEYWORDS" "$PY" -c 'import sys,json,os
kws=[w for w in os.environ.get("NODE_KEYWORDS","日本").split("|") if w]
groups={"Selector","URLTest","Fallback","LoadBalance"}
try: d=json.load(sys.stdin)["proxies"]
except Exception: sys.exit(0)
for k,v in d.items():
    if v.get("type") not in groups and any(w in k for w in kws):
        print(k)'
}

# 输出某节点延迟 ms；失败/超时输出空
clash_node_delay() {
  local enc; enc=$(clash_urlenc "$1")
  clash_api GET "/proxies/${enc}/delay?url=$(clash_urlenc "$DELAY_TEST_URL")&timeout=${DELAY_TEST_TIMEOUT}" \
    | "$PY" -c 'import sys,json
try:
    d=json.load(sys.stdin)
    if "delay" in d: print(d["delay"])
except Exception: pass'
}

# 输出某组当前选中节点
clash_current() {
  local enc; enc=$(clash_urlenc "$1")
  clash_api GET "/proxies/${enc}" | "$PY" -c 'import sys,json
try: print(json.load(sys.stdin).get("now",""))
except Exception: pass'
}

# 测所有候选节点延迟，输出最快健康节点名；无健康节点输出空
clash_pick_best() {
  local best="" bestd="" node d
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    d=$(clash_node_delay "$node")
    [[ "$d" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$bestd" ]] || (( d < bestd )); then bestd="$d"; best="$node"; fi
  done < <(clash_candidate_nodes)
  echo "$best"
}

# 切换组到指定节点。红线：拒绝切到候选关键词外的节点。成功(2xx)返回 0
clash_switch() {
  local group="$1" node="$2" enc body code
  _node_matches "$node" || return 2   # 安全红线：只切候选关键词内的节点
  [[ -S "$CLASH_SOCK" ]] || return 1
  enc=$(clash_urlenc "$group")
  body=$("$PY" -c 'import sys,json;print(json.dumps({"name":sys.argv[1]}))' "$node")
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --unix-socket "$CLASH_SOCK" \
    -X PUT -H 'Content-Type: application/json' -d "$body" \
    "http://localhost/proxies/${enc}" 2>/dev/null)
  [[ "$code" == "204" || "$code" == "200" ]]
}
