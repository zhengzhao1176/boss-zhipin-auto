#!/usr/bin/env bash
# boss.sh —— 多关键词傻瓜模式
# 流程: 顶部依次 tap 每个关键词 chip → 切「最新」→ 下拉刷新 → 自上而下点 N 个岗位 → 沟通
#
# 用法:
#   ./boss.sh                  每个关键词发 3 条(默认 3)
#   ./boss.sh 5                每个关键词发 5 条
#   DRY_RUN=1 ./boss.sh        演练不真发
#
# 关键词在脚本顶部数组里改:KEYWORDS=(...) ,OCR 用 substring 匹配
# 如果某 chip 当前不在屏幕(比如 Node.js 没在历史搜索里),会自动跳过

set -uo pipefail

# ────── 在这里配置 ──────
KEYWORDS=("全栈工" "JavaScript" "Node")    # OCR 子串匹配,Node 会匹配 Node.js / Node
DEVICE="${DEVICE:-Q4G6NRGYX4IZJ7QG}"
DRY_RUN="${DRY_RUN:-0}"
PER_KW="${1:-3}"                            # 每个关键词发几条(默认 3)
# ─────────────────────

# 内嵌 Swift OCR(返回 文字\tx\ty\tw\th)
OCR=$(mktemp -t boss_ocr.XXX.swift)
trap "rm -f '$OCR'" EXIT
cat > "$OCR" <<'SWIFT_EOF'
import Vision; import AppKit; import Foundation
let p = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: p),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let W = Double(cg.width), H = Double(cg.height)
let r = VNRecognizeTextRequest { req, _ in
    for o in (req.results as? [VNRecognizedTextObservation]) ?? [] {
        if let t = o.topCandidates(1).first {
            let b = o.boundingBox
            let x = Int(b.origin.x * W)
            let y = Int((1.0 - b.origin.y - b.size.height) * H)
            let w = Int(b.size.width * W)
            let h = Int(b.size.height * H)
            print("\(t.string)\t\(x)\t\(y)\t\(w)\t\(h)")
        }
    }
}
r.recognitionLanguages = ["zh-Hans", "en"]
r.recognitionLevel = .accurate
try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([r])
SWIFT_EOF

# ────── 助手 ──────
hwait()    { local s=$((5 + RANDOM % 6)); echo "    ⏳ ${s}s"; sleep "$s"; }
snap_ocr() { adb -s "$DEVICE" exec-out screencap -p > "$1"; swift "$OCR" "$1" > "$2"; }
adb_back() { adb -s "$DEVICE" shell input keyevent KEYCODE_BACK; }
adb_tap()  { (( DRY_RUN == 0 )) && adb -s "$DEVICE" shell input tap "$1" "$2"; }
adb_swipe(){ adb -s "$DEVICE" shell input swipe "$1" "$2" "$3" "$4" "$5"; }
tap_line() {
    IFS=$'\t' read -r text x y w h <<< "$1"
    local cx=$((x + w/2)) cy=$((y + h/2))
    echo "    ↳ tap '$text' @ ($cx,$cy)"
    adb_tap "$cx" "$cy"
}
# 在合并行(如 "附近 最新")中按词位置 tap 指定子串
tap_word() {
    local line="$1" target="$2"
    IFS=$'\t' read -r text x y w h <<< "$line"
    local -a words=($text)
    local num=${#words[@]} idx=-1
    for ((i=0; i<num; i++)); do
        if [[ "${words[$i]}" == *"$target"* ]]; then idx=$i; break; fi
    done
    local cx cy
    if (( idx >= 0 && num >= 1 )); then
        cx=$((x + w * (2*idx + 1) / (2*num)))
    else
        cx=$((x + w/2))
    fi
    cy=$((y + h/2))
    echo "    ↳ tap '$target' (在 '$text' 中) @ ($cx,$cy)"
    adb_tap "$cx" "$cy"
}
back_to_main() {
    for _ in 1 2 3 4; do
        adb -s "$DEVICE" shell dumpsys window 2>/dev/null \
            | grep -m1 mCurrentFocus | grep -q MainActivity && return 0
        adb_back; sleep 1.5
    done
}

# 前置检查
adb devices | grep -q "^${DEVICE}" || { echo "✗ 设备 $DEVICE 不在线" >&2; exit 1; }

png=$(mktemp -t b.XXX.png); txt=$(mktemp -t b.XXX.txt)
trap "rm -f '$OCR' '$png' '$txt'" EXIT

echo "════════ Boss 多关键词:${KEYWORDS[*]},每个 $PER_KW 条,DRY_RUN=$DRY_RUN ════════"

# 确认在 Boss MainActivity
snap_ocr "$png" "$txt"
if ! awk -F'\t' '{print $1}' "$txt" | grep -qE "推荐|附近|最新"; then
    echo "✗ 不在 Boss 主页(打开 Boss → 职位 tab 后再跑)"; exit 1
fi

for kw in "${KEYWORDS[@]}"; do
    echo
    echo "═══ 关键词: $kw ═══"

    # 1. 找 chip 并 tap(限制在 y<200 的顶部区域)
    snap_ocr "$png" "$txt"
    chip=$(awk -F'\t' -v k="$kw" '$3 < 200 && $1 ~ k' "$txt" | head -1)
    if [[ -z "$chip" ]]; then
        echo "  ✗ 顶部找不到 '$kw' chip,跳过"
        continue
    fi
    echo "  ▸ tap 关键词 chip"
    tap_line "$chip"
    hwait

    # 2. tap「最新」tab
    # OCR 在该设备上经常把「最新」误识别为 "I 取" / "I取" / "1 取" 等
    # 策略:先按文字匹配,失败时回退到「附近」右侧 50px 的位置
    snap_ocr "$png" "$txt"
    new_tab=$(awk -F'\t' '$3 < 250 && $1 ~ /最新/' "$txt" | head -1)
    if [[ -n "$new_tab" ]]; then
        echo "  ▸ tap 最新(文字命中)"
        tap_word "$new_tab" "最新"
        hwait
    else
        fujin=$(awk -F'\t' '$3 < 250 && $1 ~ /附近/' "$txt" | head -1)
        if [[ -n "$fujin" ]]; then
            IFS=$'\t' read -r f_t f_x f_y f_w f_h <<< "$fujin"
            cx=$((f_x + f_w + 50))
            cy=$((f_y + f_h/2))
            echo "  ▸ tap 最新(附近右侧 50px) @ ($cx,$cy)"
            adb_tap "$cx" "$cy"
            hwait
        else
            echo "  ⚠ 「附近」和「最新」都没识别到,跳过这步"
        fi
    fi

    # 3. 下拉刷新
    echo "  ▸ 下拉刷新"
    adb_swipe 360 420 360 1200 800
    hwait

    # 4. 依次点 PER_KW 个岗位 → 沟通
    for ((i=1; i<=PER_KW; i++)); do
        echo "  ─── 第 $i / $PER_KW 个岗位 ───"

        snap_ocr "$png" "$txt"
        salary=$(awk -F'\t' '$1 ~ /^[0-9]+-[0-9]+K[[:space:]]*$/' "$txt" \
            | sort -t$'\t' -k3 -n | sed -n "${i}p")
        if [[ -z "$salary" ]]; then
            echo "    ✗ 屏幕上不到 $i 个岗位,跳到下一个关键词"
            break
        fi
        tap_line "$salary"
        hwait

        snap_ocr "$png" "$txt"
        btn=$(awk -F'\t' '$1 ~ /(立即|继续)沟通/' "$txt" | head -1)
        if [[ -z "$btn" ]]; then
            echo "    ✗ 没找到沟通按钮"
            back_to_main; hwait
            continue
        fi
        hwait
        tap_line "$btn"
        hwait

        back_to_main
        hwait
    done
done

echo
echo "════════ 全部完成 ════════"
