#!/usr/bin/env bash
#
# relay.sh — CNB 云开发环境自动接力控制器
#
# 目标: 让你的服务在 CNB 云开发环境上「一直在线」。
# 平台硬限制: 单个 vscode 环境最长约 18 小时; 每日凌晨 4-6 点还会强制回收
#            使用超过 8 小时的环境; 平台无自动续期 → 需要本控制器在外部接力。
#
# 守护范围(重要): 只守护「常驻分支 prod」及 relay/* 接棒分支的环境。
#   在 main 等开发分支点「云原生开发」按钮/API 启动的临时环境 → 一律不守护、
#   不探活、不接力 → 无操作约 10 分钟后被平台自动回收, 不会误开销。
#
# 机制(分支轮换: 不同分支的环境可以并行 → 接近零停机接力):
#   1. 查询 running 环境(常驻分支 prod 或 relay/* 接棒分支)
#   2. 计算最迟回收时间 expires = min(创建+18h, 最近一次「凌晨4-6点回收点」)
#   3. 环境运行满 RELAY_SWITCH_HOURS(默认 17h), 或逼近强制回收点时, 开始接力:
#        a. 从常驻分支 prod 派生新分支 relay/<时间戳> 并推送
#        b. cnb workspace start-workspace 启动新分支环境
#        c. 轮询等待环境 running + 转发域名 HTTP 探活就绪
#        d. 调用 ddns/update.sh(若存在)切换固定域名 → 新域名
#        e. 删除旧环境(sn)与旧 relay 分支
#   4. 无论是否接力, 都对当前活跃域名做一次 HTTP 探活(探活本身即平台判定的心跳)
#   5. 若没有任何可守护的环境, 确保 prod 分支存在(从 main 派生)并启动它
#
# 运行位置: 任意装了 cnb CLI 的机器, 但必须是在 CNB 云开发环境【之外】的常开载体
#   - 本地服务器: crontab 每 30 分钟执行(见 relay/config.example.env)
#   - GitHub Actions: .github/workflows/relay.yml(需 secrets: CNB_TOKEN / RELAY_REPO)
#   警告: 不要把这个守护者放进 CNB 云开发环境里跑 —— 环境每 ~17-18h 会被回收,
#         守护者自己会先死掉, 就没人接力了。
#
# 安全: 默认 dry-run, 只读不执行任何变更; 加 --apply 才真正接力。

set -u

RELAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${RELAY_ROOT}/config.env"
[ -f "$CONFIG" ] && . "$CONFIG"

# ========== 配置与默认值 ==========
: "${RELAY_REPO:?缺少 RELAY_REPO, 请复制 relay/config.example.env 为 relay/config.env 并填写}"
: "${RELAY_PORT:=8765}"
: "${RELAY_HOST_BRANCH:=prod}"    # 常驻承载分支: 只有该分支(及 relay/* 接棒分支)的环境会被守护接力
: "${RELAY_SOURCE_BRANCH:=main}"  # 基线分支: 承载分支不存在时从它初始化派生(日常开发分支)
: "${RELAY_MAX_RUN_HOURS:=18}"     # 平台单环境时长硬上限(小时, 仅用于估算平台回收点)
: "${RELAY_SWITCH_HOURS:=17}"      # 主动接力寿命: 环境运行满该小时数即切换(默认 17h, 别顶满 18h)
: "${RELAY_AHEAD:=7200}"           # 距平台强制回收点(凌晨)的兜底提前量(秒), 默认 2h
: "${RELAY_POLL:=20}"              # 就绪轮询间隔(秒)
: "${RELAY_READY_TIMEOUT:=900}"    # 就绪等待上限(秒)
: "${RELAY_PROBE_TIMEOUT:=15}"     # 探活超时(秒)

MODE="${RELAY_MODE:-dry-run}"
[ "${1:-}" = "--apply" ] && MODE=apply

# ========== 基础工具 ==========
log() { printf '[relay %s] %s\n' "$(date '+%F %T')" "$*"; }
now_s() { date +%s; }

to_s() {  # ISO 时间 -> epoch (兼容 2026-09-06T13:18:57.000Z)
  local t="$1"
  t="$(printf '%s' "$t" | sed 's/\.[0-9]*Z$/Z/; s/T/ /; s/Z$//')"
  date -d "$t" +%s 2>/dev/null
}

# 全量 running 环境列表 → 每行一条 TSV: sn|branch|business_id|create_time|pipeline_id
ws_list_tsv() {
  cnb workspace list-workspaces --slug "$RELAY_REPO" --status running 2>/dev/null | awk '
    {
      line=$0
      # 去掉行首缩进与列表前缀 "  - "
      sub(/^ */,"",line)
      if (line ~ /^- /) { if (has("sn")) emit(); reset(); sub(/^- /,"",line) }
      if (line ~ /^[a-zA-Z_]+:/) {
        f=line; sub(/:.*/,"",f)
        v=line; sub(/^[a-zA-Z_]+: */,"",v); gsub(/\r/,"",v)
        gsub(/^"|"$/,"",v)          # YAML 字符串去引号
        K[f]=v
      }
    }
    END { emit(); }
    function has(f){ return (f in K) && K[f]!="" }
    function emit(){ if(has("sn")) printf "%s|%s|%s|%s|%s\n", K["sn"], K["branch"], K["business_id"], K["create_time"], K["pipeline_id"]; }
    function reset(){ delete K; }
  '
}

domain_of() { printf 'https://%s-%s.cnb.run/\n' "$1" "$2"; }

probe() {  # $1=url -> HTTP code / "000"
  curl -fsS -m "$RELAY_PROBE_TIMEOUT" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000
}

# 计算环境最迟回收时刻(epoch)
expires_at() {  # $1=create_time_iso $2=now_epoch
  local create="$1" now="$2" c cap=0 e day base
  c="$(to_s "$create")" || { echo 0; return 1; }
  [ -n "$c" ] || { echo 0; return 1; }
  e=$(( c + RELAY_MAX_RUN_HOURS * 3600 ))          # 候选1: 时长上限
  # 候选2: 凌晨 4-6 点强制回收「已运行 >=8h」的环境(取最近且在未来者)
  for day in 0 1; do
    base="$(date -d "$(date -d "+${day} day" +%F) 04:00:00" +%s 2>/dev/null)"
    [ -n "$base" ] || continue
    if [ "$base" -gt "$c" ] && [ $(( base - c )) -ge 28800 ] && [ "$base" -gt "$now" ]; then
      { [ "$cap" -eq 0 ] || [ "$base" -lt "$cap" ]; } && cap="$base"
    fi
  done
  { [ "$cap" -gt 0 ] && [ "$cap" -lt "$e" ]; } && e="$cap"
  echo "$e"
}

# 挑选当前「承载服务」环境(返回 TSV 行或空)
# 只守护: 常驻承载分支(默认 prod) + relay/* 接棒分支; 其它分支(如 main 开发环境)一律不守护
pick_active() {
  local all host_line relay_line="" latest_ts=0 line ts
  all="$(ws_list_tsv)"
  # 常驻分支优先
  host_line="$(printf '%s\n' "$all" | awk -F'|' -v b="$RELAY_HOST_BRANCH" '$2==b{print; exit}')"
  [ -n "$host_line" ] && { printf '%s\n' "$host_line"; return 0; }
  # 其次最新 relay/*
  while IFS='|' read -r sn br biz ct pid; do
    case "$br" in relay/*) ts="$(to_s "$ct" || echo 0)"; { [ -z "${ts:-}" ] || [ "$ts" -le "$latest_ts" ]; } && continue
      latest_ts="$ts"; relay_line="$sn|$br|$biz|$ct|$pid";; esac
  done <<< "$all"
  printf '%s\n' "${relay_line:-}"
}

# 确保常驻承载分支存在: 远端没有时, 从基线分支(main)初始化派生一次并推送
ensure_host_branch() {
  local remote
  remote="$(git_remote_with_token)"
  if git ls-remote "$remote" "refs/heads/${RELAY_HOST_BRANCH}" 2>/dev/null | grep -q .; then
    return 0
  fi
  log "远端不存在 ${RELAY_HOST_BRANCH}, 从 ${RELAY_SOURCE_BRANCH} 初始化派生"
  local r
  r="$(git ls-remote "$remote" "refs/heads/${RELAY_SOURCE_BRANCH}" 2>&1)" || { log "无法访问远端 ${RELAY_SOURCE_BRANCH}: $r"; return 1; }
  git fetch -q "$remote" "refs/heads/${RELAY_SOURCE_BRANCH}:refs/remotes/origin/_relay_host_src" 2>&1 || { log "fetch 失败"; return 1; }
  git push -q "$remote" "refs/remotes/origin/_relay_host_src:refs/heads/${RELAY_HOST_BRANCH}" 2>&1 || { log "push ${RELAY_HOST_BRANCH} 失败"; return 1; }
  git branch -q -D _relay_host_src 2>/dev/null
  log "${RELAY_HOST_BRANCH} 已创建并推送"
}

# 从常驻分支派生并推送新分支(接棒分支)
create_branch_from_host() {  # $1=new_branch
  local remote r
  remote="$(git_remote_with_token)"
  r="$(git ls-remote "$remote" "refs/heads/${RELAY_HOST_BRANCH}" 2>&1)" || { log "无法访问远端: $r"; return 1; }
  git fetch -q "$remote" "refs/heads/${RELAY_HOST_BRANCH}:refs/remotes/origin/_relay_base" 2>&1 || { log "fetch 失败"; return 1; }
  git push -q "$remote" "refs/remotes/origin/_relay_base:refs/heads/${1}" 2>&1 || { log "push 失败"; return 1; }
  git branch -q -D _relay_base 2>/dev/null
}

git_remote_with_token() {
  [ -n "${RELAY_GIT_REMOTE:-}" ] && { printf '%s\n' "$RELAY_GIT_REMOTE"; return; }
  if [ -n "${CNB_TOKEN:-}" ]; then
    printf 'https://oauth2:%s@cnb.cool/%s.git\n' "$CNB_TOKEN" "$RELAY_REPO"
  else
    printf 'https://cnb.cool/%s.git\n' "$RELAY_REPO"
  fi
}

# DDNS 钩子: ddns/update.sh 存在则调用, 否则打印新域名
ddns_update() {  # $1=domain $2=port $3=business_id
  local ddns
  ddns="$(cd "$RELAY_ROOT/.." && pwd)/ddns/update.sh"
  if [ -f "$ddns" ] && [ -x "$ddns" ]; then
    log "调用 DDNS 钩子: ${ddns} $1 $2 $3"
    bash "$ddns" "$1" "$2" "$3"
  else
    log "新域名(尚未配置 ddns/update.sh, 参考 ddns/update.example.sh): $1"
  fi
}

# 启动分支环境, 轮询至就绪, 然后 DDNS + 清理旧环境
start_and_wait() {  # $1=branch  $2=旧环境 TSV(可空)
  local branch="$1" old_line="$2" t0 new_line sn biz d code
  log "启动环境: branch=${branch}"
  cnb workspace start-workspace --repo "$RELAY_REPO" --branch "$branch" >/dev/null 2>&1 \
    || { log "start-workspace 失败"; return 1; }

  t0="$(now_s)"
  while :; do
    new_line="$(ws_list_tsv | awk -F'|' -v b="$branch" '$2==b{print; exit}')"
    if [ -n "$new_line" ]; then
      sn="$(printf '%s' "$new_line" | cut -d'|' -f1)"
      biz="$(printf '%s' "$new_line" | cut -d'|' -f3)"
      if [ -n "$biz" ] && [ "$biz" != "$new_line" ]; then
        d="$(domain_of "$biz" "$RELAY_PORT")"
        code="$(probe "$d")"
        log "环境 ${branch} running: sn=${sn} 探活 ${d} → HTTP ${code}"
        if [ "$code" != "000" ]; then break; fi
      else
        log "环境 ${branch} running(sn=${sn}), 等待 business_id…"
      fi
    else
      log "环境 ${branch} 尚未 running, ${RELAY_POLL}s 后重试…"
    fi
    [ $(( $(now_s) - t0 )) -gt "$RELAY_READY_TIMEOUT" ] && { log "就绪等待超时"; return 1; }
    sleep "$RELAY_POLL"
  done

  log "新环境就绪: branch=${branch} sn=${sn} domain=${d}"
  ddns_update "$d" "$RELAY_PORT" "$biz"

  if [ -n "$old_line" ]; then
    local old_sn old_br
    old_sn="$(printf '%s' "$old_line" | cut -d'|' -f1)"
    old_br="$(printf '%s' "$old_line" | cut -d'|' -f2)"
    if [ "$old_sn" != "$sn" ]; then
      log "删除旧环境 sn=${old_sn} (branch=${old_br})"
      cnb workspace delete-workspace --sn "$old_sn" >/dev/null 2>&1 \
        && log "旧环境已删除" || log "旧环境删除失败(可能已被平台回收)"
      case "$old_br" in
        relay/*) [ "$old_br" != "$branch" ] \
          && { git push -q "$(git_remote_with_token)" --delete "refs/heads/${old_br}" 2>/dev/null \
               && log "旧分支 ${old_br} 已删除" || log "旧分支删除失败(可手动清理)"; };;
      esac
    fi
  fi
}

# ========== 主流程 ==========
main() {
  local now active sn br biz ct pid d code cs runtime hard switch_at need why
  now="$(now_s)"
  log "=== 轮询 (repo=${RELAY_REPO} port=${RELAY_PORT} mode=${MODE}) ==="

  active="$(pick_active)"

  # 1) 没有任何 running 环境 → 确保承载分支存在并启动它
  if [ -z "$active" ]; then
    log "当前没有可守护的 running 环境(常驻分支=${RELAY_HOST_BRANCH}, 接棒分支=relay/*)"
    if [ "$MODE" = "apply" ]; then
      ensure_host_branch || { log "承载分支初始化失败, 本轮结束"; return 1; }
      start_and_wait "$RELAY_HOST_BRANCH" "" || return 1
    else
      log "[dry-run] 将执行: 确保 ${RELAY_HOST_BRANCH} 存在 → start-workspace --branch ${RELAY_HOST_BRANCH} → 探活 → DDNS"
    fi
    return 0
  fi

  IFS='|' read -r sn br biz ct pid <<< "$active"
  cs="$(to_s "$ct")"; { [ -z "$cs" ] || [ "$cs" -le 0 ]; } && cs="$now"
  runtime=$(( now - cs ))
  hard="$(expires_at "$ct" "$now")"                      # 平台真实最迟回收点
  switch_at=$(( cs + RELAY_SWITCH_HOURS * 3600 ))         # 计划主动切换点
  log "当前承载环境: branch=${br} sn=${sn} business_id=${biz}"
  log "  已运行 $((runtime/3600))h$(((runtime%3600)/60))m | 计划 ${RELAY_SWITCH_HOURS}h 切换点: $(date -d "@${switch_at}" '+%F %T')"
  log "  平台强制回收点: $(date -d "@${hard}" '+%F %T') (距现在 $(( (hard-now)/3600 ))h$(( ((hard-now)%3600)/60 ))m)"

  # 2) 决策: 运行满 RELAY_SWITCH_HOURS 主动切换; 或逼近平台凌晨强制回收时兜底提前
  local need=0 why=""
  if [ "$runtime" -ge $(( RELAY_SWITCH_HOURS * 3600 )) ]; then
    need=1; why="已运行满 ${RELAY_SWITCH_HOURS}h(计划主动切换, 不顶平台 18h 极限)"
  elif [ $(( hard - now )) -le "$RELAY_AHEAD" ]; then
    need=1; why="距平台强制回收点不足 ${RELAY_AHEAD}s, 需提前接棒"
  fi

  if [ "$need" -eq 0 ]; then
    d="$(domain_of "$biz" "$RELAY_PORT")"
    code="$(probe "$d")"
    log "寿命充足(策略: 运行满 ${RELAY_SWITCH_HOURS}h 才切换), 无需接力"
    log "  探活 ${d} → HTTP ${code}"
    [ "$code" = "000" ] && log "  警告: 服务不可达(请检查程序; 转发域名探活同时是环境保活心跳)"
    return 0
  fi

  # 3) 触发接力
  local new_branch="relay/$(date +%s)"
  log "触发接力: ${why} → 接棒分支 ${new_branch}"
  if [ "$MODE" = "apply" ]; then
    create_branch_from_host "$new_branch" || { log "派生分支失败, 放弃本轮"; return 1; }
    start_and_wait "$new_branch" "$active" || { log "接力失败, 保持现状"; return 1; }
  else
    log "[dry-run] 将执行:"
    log "  1) 从常驻分支 ${RELAY_HOST_BRANCH} 派生并推送 ${new_branch}"
    log "  2) start-workspace --branch ${new_branch}"
    log "  3) 轮询就绪 → HTTP 探活 ${RELAY_PORT} 端口"
    log "  4) ddns/update.sh 切换域名"
    log "  5) 删除旧环境 sn=${sn} (branch=${br})"
    case "$br" in
      relay/*) log "     并删除旧 relay 分支 ${br}";;
    esac
  fi
  return 0
}

main "$@"
