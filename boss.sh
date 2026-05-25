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
KEYWORDS=("全栈工" "JavaScript" "Node")    # 顶部 chip:OCR 子串匹配,Node 会匹配 Node.js / Node
DEVICE="${DEVICE:-Q4G6NRGYX4IZJ7QG}"
DRY_RUN="${DRY_RUN:-0}"
PER_KW="${1:-3}"                            # 每个关键词发几条(默认 3)
# 岗位标题必须命中下列正则才点击(同 y 行任意文字命中即可)
# 匹配时整段先转小写(全大小写不敏感),所以 pattern 写小写即可
# 含:全栈 / node(覆盖 Node / node.js / Node.JS / NodeJS)/ php / javascript / ai(含 AIGC / AIOps)
# AI 用「左单词边界」(前面必须不是字母),避免误伤 trainee / captain / detail / email / maine
TITLE_REGEX='全栈|node|php|javascript|(^|[^a-z])ai'
MAX_REFRESH=5                               # 凑不够 PER_KW 时最多下拉刷新次数
# 已沟通公司历史文件(命中已记录公司自动跳过,成功后自动追加)
CONTACTED_FILE="${CONTACTED_FILE:-$(dirname "${BASH_SOURCE[0]}")/boss_contacted.txt}"
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

# 已沟通公司查重(注:Mac bash 3.2 没有关联数组,直接 grep 文件)
# -aF: -a 把含中文(多字节)的文件当文本处理,-F 字面字符串
is_contacted() {
    local c="$1"
    [[ -z "$c" ]] && return 1
    [[ ! -f "$CONTACTED_FILE" ]] && return 1
    grep -aqF " | $c | " "$CONTACTED_FILE"
}
contacted_count=0
[[ -f "$CONTACTED_FILE" ]] && contacted_count=$(grep -ac '^\[' "$CONTACTED_FILE" 2>/dev/null || echo 0)

echo "════════ Boss 多关键词:${KEYWORDS[*]},每个 $PER_KW 条,DRY_RUN=$DRY_RUN ════════"
echo "[历史] 已沟通 $contacted_count 家(命中已沟通公司自动跳过,记录:$CONTACTED_FILE)"

# 确认在 Boss MainActivity
snap_ocr "$png" "$txt"
if ! awk -F'\t' '{print $1}' "$txt" | grep -qE "推荐|附近|最新"; then
    echo "✗ 不在 Boss 主页(打开 Boss → 职位 tab 后再跑)"; exit 1
fi

for kw in "${KEYWORDS[@]}"; do
    echo
    echo "═══ 关键词: $kw ═══"

    # 1. 找 chip 并 tap
    # Boss 主页 chip 栏只显示常用 2 个,完整历史只在「点过任一 chip 后的结果页」才显示
    # 策略:先在当前页找;找不到则点任一可见 chip 进入结果页,再左右横扫定位
    chip=""
    snap_ocr "$png" "$txt"
    chip=$(awk -F'\t' -v k="$kw" '$3 < 200 && $1 ~ k' "$txt" | head -1)

    if [[ -z "$chip" ]]; then
        # 优先选 KEYWORDS 里的其他 chip 当 seed (避免污染 chip 历史)
        # 例如找 Node 时,优先点 全栈工程师,而不是随便点 兼职 / 培训类 chip
        seed=""
        for other_kw in "${KEYWORDS[@]}"; do
            [[ "$other_kw" == "$kw" ]] && continue
            seed=$(awk -F'\t' -v k="$other_kw" '$3 > 70 && $3 < 140 && $2 < 500 && $4 > 50 && $1 ~ k' "$txt" | head -1)
            [[ -n "$seed" ]] && break
        done
        # 兜底:任一可见 chip
        if [[ -z "$seed" ]]; then
            seed=$(awk -F'\t' '$3 > 70 && $3 < 140 && $2 < 500 && $4 > 50' "$txt" | head -1)
        fi
        if [[ -n "$seed" ]]; then
            seed_text=$(echo "$seed" | cut -f1)
            echo "  · 当前页没看到 '$kw',先点 '$seed_text' 展开完整 chip 历史"
            tap_line "$seed"
            hwait
        fi
        # 结果页 chip 栏支持横扫,试两个方向(共 8 次)
        for attempt in 1 2 3 4 5 6 7 8; do
            snap_ocr "$png" "$txt"
            chip=$(awk -F'\t' -v k="$kw" '$3 < 200 && $1 ~ k' "$txt" | head -1)
            [[ -n "$chip" ]] && break
            if (( attempt <= 4 )); then
                echo "  · 横扫 chip 栏 → 露出右侧 ($attempt/8)"
                adb_swipe 550 105 100 105 400
            else
                echo "  · 横扫 chip 栏 ← 露出左侧 ($attempt/8)"
                adb_swipe 100 105 550 105 400
            fi
            sleep 1.5
        done
    fi

    if [[ -z "$chip" ]]; then
        echo "  ✗ 找不到 '$kw' chip,跳过"
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

    # 4. 找标题命中 TITLE_REGEX 的岗位,凑够 PER_KW 个;不够就下拉刷新继续
    clicked=0
    refresh=0
    skip=0
    while (( clicked < PER_KW && refresh <= MAX_REFRESH )); do
        snap_ocr "$png" "$txt"

        # 对每条工资行(X-YK):
        #   - 同 y 行(±25px)看是否命中 TITLE_REGEX → 提取 title
        #   - 标题正下方 35-85px 处看公司行(用于去重)
        # 输出: salary_text\tx\ty\tw\th\ttitle\tcompany_raw
        matches=$(awk -F'\t' -v kw="$TITLE_REGEX" '
            # ltext: 小写版,用于关键字匹配(中文不变,英文转小写)
            { text[NR]=$1; ltext[NR]=tolower($1); x[NR]=$2; y[NR]=$3; w[NR]=$4; h[NR]=$5 }
            END {
                for (i=1; i<=NR; i++) {
                    if (text[i] !~ /^[0-9]+-[0-9]+K[ \t]*$/) continue
                    sy = y[i]
                    title = ""
                    company = ""
                    company_x = 9999
                    for (j=1; j<=NR; j++) {
                        if (j == i) continue
                        # 标题:同行 ±25,x<400,关键字大小写不敏感
                        if (title == "" && y[j] >= sy-25 && y[j] <= sy+25 && x[j] < 400 && ltext[j] ~ kw) {
                            title = text[j]
                        }
                        # 公司行:标题下方 35-130px(放宽以覆盖长标题换行),左侧
                        # 必须像公司行(含「轮/融资/X-Y人/已上市」),避免误抓到标题第二行
                        if (y[j] > sy+35 && y[j] < sy+130 && x[j] < 400 && x[j] < company_x \
                            && text[j] ~ /轮|融资|[0-9]+人|已上市/) {
                            company = text[j]
                            company_x = x[j]
                        }
                    }
                    if (title != "") {
                        print text[i]"\t"x[i]"\t"y[i]"\t"w[i]"\t"h[i]"\t"title"\t"company
                    }
                }
            }
        ' "$txt" | sort -t$'\t' -k3 -n)

        # 遍历命中行,跳过已沟通公司,取第一个未沟通的
        selected=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            comp_raw=$(echo "$line" | cut -f7)
            # 取第一个空格前的内容做去重 key(去掉 "X-Y人 X轮 行业" 等后缀)
            comp_key=$(echo "$comp_raw" | awk '{print $1}')
            if is_contacted "$comp_key"; then
                t=$(echo "$line" | cut -f6)
                echo "    ⊘ 跳过已沟通公司 '$comp_key' (岗位:'$t')"
                continue
            fi
            selected="$line"
            break
        done <<< "$matches"

        if [[ -z "$selected" ]] || (( skip >= 2 )); then
            reason="屏幕无新岗位(已沟通已跳过或无标题命中)"
            (( skip >= 2 )) && reason="连续 $skip 次卡同位置/无沟通按钮"
            ((refresh++))
            echo "    · $reason → 下拉刷新 ($refresh/$MAX_REFRESH)"
            adb_swipe 360 420 360 1200 800
            hwait
            skip=0
            continue
        fi

        salary_line=$(echo "$selected" | cut -f1-5)
        title=$(echo "$selected" | cut -f6)
        company_raw=$(echo "$selected" | cut -f7)
        company=$(echo "$company_raw" | awk '{print $1}')
        [[ -z "$company" ]] && company="(未识别)"

        echo "  ─── 第 $((clicked+1)) / $PER_KW 个岗位(标题:'$title' / 公司:'$company')───"
        tap_line "$salary_line"
        hwait

        snap_ocr "$png" "$txt"
        # 只点「立即沟通」;「继续沟通」=已聊过,跳过避免重发
        btn=$(awk -F'\t' '$1 ~ /立即沟通/' "$txt" | head -1)
        if [[ -z "$btn" ]]; then
            echo "    ✗ 没找到立即沟通(可能已沟通过/页面没加载好)"
            back_to_main; hwait
            ((skip++))
            continue
        fi
        hwait
        tap_line "$btn"
        hwait
        ((clicked++))
        skip=0

        # 记录已沟通(同进程后续 is_contacted 也能查到)
        if [[ "$company" != "(未识别)" && "$DRY_RUN" == "0" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] | $company | $title" >> "$CONTACTED_FILE"
            echo "    ✓ 已记录:$company"
        fi

        back_to_main
        hwait
    done

    if (( clicked < PER_KW )); then
        echo "  ⚠ 已刷新 $refresh 次仍不够,本关键词实际点击 $clicked / $PER_KW"
    else
        echo "  ✓ 本关键词完成 $clicked / $PER_KW"
    fi
done

echo
echo "════════ 全部完成 ════════"
