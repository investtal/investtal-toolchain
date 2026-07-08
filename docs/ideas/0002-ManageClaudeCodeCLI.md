# **Báo Cáo Giải Pháp: Kiến Trúc Điều Phối Đa Mô Hình Linh Hoạt Cho Claude Code Qua Cổng Gateway 9Router**

Sự phát triển của các tác nhân lập trình tự động (AI coding agents) đòi hỏi sự kết hợp linh hoạt giữa các mô hình ngôn ngữ lớn (LLM) để tối ưu hóa cả về mặt hiệu năng lập luận lẫn chi phí vận hành1. Công cụ Claude Code từ Anthropic đã chứng minh năng lực vượt trội trong việc phân tích mã nguồn và thực thi các tác vụ lập trình phức tạp3. Tuy nhiên, việc chuyển đổi thủ công cấu hình trong tệp settings.json mỗi khi cần thay đổi mô hình hoặc chuyển tiếp giữa các giai đoạn lập kế hoạch (planning) và thực thi (execution) đang là rào cản lớn đối với các đội ngũ phát triển muốn tự động hóa hoàn toàn quy trình này5.  
Báo cáo này phân tích chi tiết cơ chế cấu hình động của Claude Code, đề xuất giải pháp tích hợp thông qua hệ thống phân phối yêu cầu 9Router7, và cung cấp bộ công cụ CLI viết bằng Bash và PowerShell để tự động hóa toàn bộ quy trình vận hành đa mô hình.

## **1\. Phân Tích Kiến Trúc Và Cơ Chế Tương Tác Giữa Claude Code Và 9Router**

Kiến trúc tích hợp giữa Claude Code, 9Router, và các nhà cung cấp mô hình AI dựa trên nguyên lý hoạt động của một cổng LLM Gateway cục bộ hoặc phân tán7. 9Router đóng vai trò làm proxy trung gian, tiếp nhận các yêu cầu định dạng Anthropic Messages API từ Claude Code, thực hiện dịch thuật định dạng (format translation) sang chuẩn của nhà cung cấp đích, theo dõi định mức (quota tracking), và tự động kích hoạt cơ chế dự phòng (fallback) khi có sự cố7.  
Để hiểu rõ cách thức tối ưu hóa luồng dữ liệu, bảng dưới đây tổng hợp thông số cấu hình tối ưu cho 13 mô hình mục tiêu trong hệ thống thông qua cổng kết nối 9Router:

| Mã định danh mô hình (Model ID) | Nhà cung cấp gốc (Provider) | Kích thước cửa sổ nén tối ưu (Auto Compact Window) | Vai trò khuyến nghị trong dự án |
| :---- | :---- | :---- | :---- |
| cc/fable-5 | Anthropic (via 9Router) | 200,0004 | Lập kế hoạch kiến trúc, giải quyết tác vụ phức tạp bậc cao5 |
| cc/claude-opus-4-8 | Anthropic (via 9Router) | 200,0004 | Lập luận logic phức tạp, phân tích hệ thống sâu5 |
| cc/claude-sonnet-5 | Anthropic (via 9Router) | 200,0004 | Viết mã nguồn hàng ngày, tái cấu trúc mã5 |
| cc/claude-haiku-4-5-20251001 | Anthropic (via 9Router) | 200,0004 | Kiểm thử nhanh, sửa lỗi lint, viết tài liệu10 |
| cx/gpt-5.5 | OpenAI (via 9Router) | 128,000 | Lập trình đa ngôn ngữ, tối ưu thuật toán |
| glm/glm-5.2 | Z.AI / GLM (via 9Router) | 1,000,00012 | Phân tích toàn bộ kho mã nguồn lớn (Large Context)2 |
| glm/glm-5-turbo | Z.AI / GLM (via 9Router) | 1,000,00012 | Phân tích mã nguồn tốc độ cao, xử lý song song2 |
| ds/deepseek-v4-pro | DeepSeek (via 9Router) | 1,000,00010 | Lập trình logic, tối ưu hóa hiệu năng chuyên sâu10 |
| ds/deepseek-v4-flash | DeepSeek (via 9Router) | 1,000,00010 | Thực thi nhanh, viết test case tự động10 |
| kimi/kimi-k2.7 | Moonshot / Kimi (via 9Router) | 1,000,000 | Phân tích mã nguồn dài, tra cứu tài liệu kỹ thuật13 |
| gc/grok-build | xAI / Grok (via 9Router) | 500,000 | Tích hợp hệ thống, kiểm thử tích hợp chuyên sâu |
| gc/grok-composer-2.5-fast | xAI / Grok (via 9Router) | 500,000 | Viết mã nguồn nhanh, sinh boilerplate code |
| minimax/MiniMax-M3 | MiniMax (via 9Router) | 1,000,00015 | Lập trình tác vụ dài hạn, xử lý ngữ cảnh cực lớn15 |

Trong mô hình này, việc cấu hình Claude Code trở nên linh hoạt hơn nhờ vào cơ chế ưu tiên nạp biến môi trường của hệ thống15. Các biến môi trường thiết lập trực tiếp tại thời điểm khởi chạy hoặc định nghĩa trong khối env của file settings.json sẽ ghi đè lên cấu hình mặc định15.  
Thứ tự ưu tiên cấu hình của Claude Code được áp dụng chặt chẽ từ trên xuống dưới, cho phép kiểm soát linh hoạt ở từng cấp độ hệ thống18:

1. **Chính sách quản lý doanh nghiệp (Managed Policy):** Cấu hình cố định bởi quản trị viên IT thông qua các file cấu hình hệ thống không thể bị ghi đè bởi người dùng18.  
2. **Đối số dòng lệnh (CLI Flags):** Các cờ cấu hình trực tiếp khi chạy lệnh (ví dụ: \--model, \--permission-mode)5.  
3. **Biến môi trường (Environment Variables):** Các biến được xuất (export hoặc $env:) trong phiên làm việc hiện tại10. Các biến này có mức ưu tiên cao tuyệt đối so với các tệp cấu hình JSON tĩnh, cho phép ghi đè toàn bộ tham số kết nối mà không cần chỉnh sửa tệp vật lý15.  
4. **Cấu hình dự án cục bộ (Local Project Settings):** Định nghĩa tại .claude/settings.local.json (thường được đưa vào .gitignore)18.  
5. **Cấu hình dự án dùng chung (Project Settings):** Định nghĩa tại .claude/settings.json và được commit vào Git18.  
6. **Cấu hình người dùng toàn cục (User Settings):** Định nghĩa tại file cấu hình mặc định hệ thống \~/.claude/settings.json3.

## **2\. Giải Pháp Giải Quyết Tận Gốc Bài Toán Chuyển Đổi Mô Hình (Model Switching)**

### **Chuyển Đổi Mô Hình Trực Tiếp Trong Phiên Làm Việc Hiện Tại (In-Session Switching)**

Để thực hiện chuyển đổi mô hình mà không cần khởi động lại phiên làm việc (session), nhà phát triển có thể tận dụng cấu hình availableModels kết hợp với modelOverrides ngay trong file cấu hình \~/.claude/settings.json5.  
Thông thường, Claude Code thực hiện xác thực nghiêm ngặt danh sách mã mô hình (Model ID) được phép chạy trên Anthropic API5. Tuy nhiên, khi định tuyến qua một LLM Gateway tùy chỉnh như 9Router bằng cách thay đổi biến ANTHROPIC\_BASE\_URL, cơ chế kiểm tra nghiêm ngặt này được nới lỏng hoặc bỏ qua trên các endpoint không thuộc Anthropic5. Điều này cho phép định nghĩa các tên mô hình tùy chỉnh đại diện cho các cổng định tuyến của 9Router9.  
Bằng cách khai báo danh sách mô hình đích vào mảng availableModels trong \~/.claude/settings.json, tổ hợp phím tắt chuyển đổi mô hình cục bộ Option+P (trên macOS) hoặc Alt+P (trên Windows/Linux) sẽ hiển thị menu lựa chọn trực quan ngay trong phiên TUI đang hoạt động4. Người dùng cũng có thể gõ trực tiếp lệnh /model \<model\_id\> (ví dụ: /model minimax/MiniMax-M3) để chuyển đổi tức thì5.  
Khi thay đổi mô hình mid-session, một vấn đề phát sinh là biến môi trường CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW (thiết lập dung lượng tối đa của cửa sổ ngữ cảnh trước khi nén) vốn được nạp cố định lúc khởi chạy và không thể thay đổi động trong TUI15. Nếu cấu hình giá trị này quá thấp (ví dụ: mặc định 200,000 tokens của Claude), khi chuyển sang các mô hình ngữ cảnh lớn như MiniMax-M3 hoặc GLM-5.2 (hỗ trợ tới 1,000,000 tokens), hệ thống sẽ kích hoạt tiến trình nén ngữ cảnh sớm một cách không cần thiết, làm mất đi các chi tiết logic sâu của cấu trúc mã nguồn đã tích lũy12.  
**Giải pháp:** Cấu hình cố định CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW ở mức tối đa là 1000000 ngay tại thời điểm khởi chạy thông qua tệp cấu hình toàn cục15. Điều này đảm bảo khi người dùng chuyển đổi sang bất kỳ mô hình nào trong session, cửa sổ ngữ cảnh luôn được tối ưu hóa ở mức cao nhất mà không gây xung đột hệ thống12.

### **Quy Trình Lập Kế Hoạch Và Thực Thi Tự Động Hóa Không Can Thiệp (Unattended Automation)**

Nhu cầu tự động hóa quy trình lập trình khi đội ngũ phát triển không túc trực (chạy tác vụ qua đêm) đòi hỏi một cơ chế chuyển giao trạng thái thông minh giữa hai giai đoạn26:

1. **Giai đoạn lập kế hoạch (Planning Phase):** Sử dụng mô hình có khả năng lập luận xuất sắc nhất (cc/fable-5) để phân tích yêu cầu, khảo sát cấu trúc thư mục, và xuất ra một tài liệu kế hoạch hành động chi tiết dưới dạng tệp Markdown (CLAUDE\_PLAN.md)4.  
2. **Giai đoạn thực thi (Execution Phase):** Chuyển giao tệp CLAUDE\_PLAN.md sang một mô hình tối ưu về chi phí và tốc độ viết mã (như minimax/MiniMax-M3 hoặc kimi/kimi-k2.7) để tiến hành hiện thực hóa mã nguồn, chạy thử nghiệm và sửa lỗi tự động13.

Quy trình này hoạt động dựa trên nguyên lý **Chuyển giao trạng thái dựa trên Workspace (Workspace-driven State Transfer)**4. Vì Claude Code luôn quét toàn bộ cấu trúc Git và các tệp tài liệu hướng dẫn dự án (như CLAUDE.md) khi khởi chạy, việc lưu trữ kế hoạch vào một tệp tin vật lý trong thư mục dự án cho phép phiên làm việc mới kế thừa hoàn hảo bối cảnh của phiên làm việc trước mà không cần duy trì một tiến trình RAM liên tục4.  
Để chạy hoàn toàn tự động mà không cần con người phê duyệt từng hành động (như tạo thư mục, sửa tệp, hoặc chạy lệnh bash kiểm thử), phiên thực thi thứ hai bắt buộc phải khởi chạy với chế độ không tương tác (non-interactive) thông qua cờ \-p kết hợp với cờ bỏ qua xác thực quyền \--dangerously-skip-permissions (tương đương với \--permission-mode bypassPermissions)20. Điều này cho phép tác nhân AI tự động duyệt mọi thao tác chỉnh sửa hệ thống tệp và thực thi lệnh shell một cách liền mạch26.

## **3\. Bộ Công Cụ CLI Điều Phối Đa Mô Hình Toàn Diện: 9cc**

Để đơn giản hóa việc quản lý, bộ công cụ CLI tên là 9cc được phát triển dưới hai dạng kịch bản điều khiển tương thích hoàn toàn với tất cả hệ điều hành phổ biến: Bash (cho Linux, macOS, WSL) và PowerShell (cho Windows native)3.  
Bộ công cụ này tự động hóa việc thiết lập các biến môi trường cấu hình của Claude Code trước khi khởi chạy, đồng thời cung cấp quy trình "Auto-Pilot" hai giai đoạn chạy qua đêm cực kỳ mạnh mẽ15.

### **Kịch Bản Bash CLI (9cc.sh) \- Dành Cho macOS, Linux Và WSL**

Người dùng lưu mã nguồn dưới đây thành tệp 9cc.sh, cấp quyền thực thi bằng lệnh chmod \+x 9cc.sh, và có thể tạo liên kết tượng trưng toàn cục bằng lệnh ln \-sf /path/to/9cc.sh /usr/local/bin/9cc để gọi từ bất kỳ thư mục dự án nào1.

Bash  
\#\!/usr/bin/env bash  
\# \==============================================================================  
\# Lệnh quản lý mô hình Claude Code kết hợp cổng LLM Gateway 9Router  
\# Hỗ trợ: macOS, Linux, WSL  
\# \==============================================================================

\# Thư mục cấu hình hệ thống  
CLAUDE\_CONFIG\_DIR="$HOME/.claude"  
CLAUDE\_CONFIG\_FILE="$CLAUDE\_CONFIG\_DIR/settings.json"  
CONFIG\_ENV\_DIR="$HOME/.config/9cc"  
CONFIG\_ENV\_FILE="$CONFIG\_ENV\_DIR/9cc.env"

\# Khởi tạo thư mục nếu chưa tồn tại  
mkdir \-p "$CLAUDE\_CONFIG\_DIR"  
mkdir \-p "$CONFIG\_ENV\_DIR"

\# Nạp cấu hình kết nối 9Router  
if \[ \-f "$CONFIG\_ENV\_FILE" \]; then  
    source "$CONFIG\_ENV\_FILE"  
else  
    \# Giá trị cấu hình mặc định trỏ về 9Router chạy cục bộ  
    NINE\_ROUTER\_URL="http://localhost:20128/v1"  
    NINE\_ROUTER\_TOKEN="default\_9router\_api\_key"  
    echo "NINE\_ROUTER\_URL=\\"$NINE\_ROUTER\_URL\\"" \> "$CONFIG\_ENV\_FILE"  
    echo "NINE\_ROUTER\_TOKEN=\\"$NINE\_ROUTER\_TOKEN\\"" \>\> "$CONFIG\_ENV\_FILE"  
fi

\# Ánh xạ tên viết tắt (alias) sang Model ID gốc của 9Router và kích thước cửa sổ thu gọn tối ưu  
get\_model\_properties() {  
    local key="$1"  
    case "$key" in  
        fable)          echo "cc/fable-5|200000" ;;  
        opus)           echo "cc/claude-opus-4-8|200000" ;;  
        sonnet)         echo "cc/claude-sonnet-5|200000" ;;  
        haiku)          echo "cc/claude-haiku-4-5-20251001|200000" ;;  
        gpt5)           echo "cx/gpt-5.5|128000" ;;  
        glm5)           echo "glm/glm-5.2|1000000" ;;  
        glmturbo)       echo "glm/glm-5-turbo|1000000" ;;  
        deepseek)       echo "ds/deepseek-v4-pro|1000000" ;;  
        dsflash)        echo "ds/deepseek-v4-flash|1000000" ;;  
        kimi)           echo "kimi/kimi-k2.7|1000000" ;;  
        grok)           echo "gc/grok-build|500000" ;;  
        grokcomposer)   echo "gc/grok-composer-2.5-fast|500000" ;;  
        minimax)        echo "minimax/MiniMax-M3|1000000" ;;  
        \*)              echo "INVALID" ;;  
    esac  
}

show\_help() {  
    echo "Hệ thống Điều phối Đa Mô hình Claude Code qua 9Router (9cc)"  
    echo "Cách sử dụng:"  
    echo "  ./9cc.sh setup                     Cấu hình thông số endpoint và API Key cho 9Router"  
    echo "  ./9cc.sh list                      Liệt kê tất cả các mô hình được hỗ trợ và thông số nén"  
    echo "  ./9cc.sh run \<alias\> \[args...\]     Khởi chạy phiên Claude Code với mô hình được chọn"  
    echo "  ./9cc.sh set-default \<alias\>       Thiết lập mô hình mặc định tĩnh trong settings.json"  
    echo "  ./9cc.sh auto-pilot \\"\<yêu\_cầu\>\\"    Quy trình lập kế hoạch (Fable 5\) & Thực thi tự động (Minimax) qua đêm"  
    echo ""  
    echo "Ví dụ:"  
    echo "  ./9cc.sh run sonnet"  
    echo "  ./9cc.sh run minimax \--dangerously-skip-permissions"  
    echo "  ./9cc.sh auto-pilot \\"Hãy viết unit test toàn bộ thư mục controller này\\""  
}

write\_claude\_settings\_json() {  
    local default\_model="$1"  
    local compact\_size="$2"

    cat \<\<EOF \> "$CLAUDE\_CONFIG\_FILE"  
{  
  "model": "$default\_model",  
  "availableModels": \[  
    "cc/fable-5",  
    "cc/claude-opus-4-8",  
    "cc/claude-sonnet-5",  
    "cc/claude-haiku-4-5-20251001",  
    "cx/gpt-5.5",  
    "glm/glm-5.2",  
    "glm/glm-5-turbo",  
    "ds/deepseek-v4-pro",  
    "ds/deepseek-v4-flash",  
    "kimi/kimi-k2.7",  
    "gc/grok-build",  
    "gc/grok-composer-2.5-fast",  
    "minimax/MiniMax-M3"  
  \],  
  "modelOverrides": {  
    "claude-opus-4-6": "cc/claude-opus-4-8",  
    "claude-sonnet-4-6": "cc/claude-sonnet-5",  
    "claude-haiku-4-5-20251001": "cc/claude-haiku-4-5-20251001"  
  },  
  "env": {  
    "ANTHROPIC\_BASE\_URL": "$NINE\_ROUTER\_URL",  
    "ANTHROPIC\_AUTH\_TOKEN": "$NINE\_ROUTER\_TOKEN",  
    "CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW": "$compact\_size"  
  }  
}  
EOF  
}

setup\_9router() {  
    read \-p "Nhập URL endpoint 9Router \[$NINE\_ROUTER\_URL\]: " input\_url  
    NINE\_ROUTER\_URL=${input\_url:-$NINE\_ROUTER\_URL}  
      
    read \-p "Nhập mã API Key của 9Router \[$NINE\_ROUTER\_TOKEN\]: " input\_token  
    NINE\_ROUTER\_TOKEN=${input\_token:-$NINE\_ROUTER\_TOKEN}

    echo "NINE\_ROUTER\_URL=\\"$NINE\_ROUTER\_URL\\"" \> "$CONFIG\_ENV\_FILE"  
    echo "NINE\_ROUTER\_TOKEN=\\"$NINE\_ROUTER\_TOKEN\\"" \>\> "$CONFIG\_ENV\_FILE"  
      
    \# Thiết lập file settings.json mặc định với kích thước compact lớn nhất để hỗ trợ switch động trong session  
    write\_claude\_settings\_json "cc/claude-sonnet-5" "1000000"  
    echo "Cấu hình thành công hệ thống tệp tin tại: $CLAUDE\_CONFIG\_FILE"  
}

list\_models() {  
    printf "%-15s | %-30s | %-20s\\n" "Phím tắt (Alias)" "Mã định danh 9Router" "Cửa sổ nén mặc định"  
    echo "--------------------------------------------------------------------------------"  
    for alias in fable opus sonnet haiku gpt5 glm5 glmturbo deepseek dsflash kimi grok grokcomposer minimax; do  
        properties=$(get\_model\_properties "$alias")  
        IFS='|' read \-r fullname window \<\<\< "$properties"  
        printf "%-15s | %-30s | %-20s\\n" "$alias" "$fullname" "$window"  
    done  
}

run\_session() {  
    local alias\="$1"  
    shift  
    local extra\_args=("$@")

    local properties=$(get\_model\_properties "$alias")  
    if \[ "$properties" \== "INVALID" \]; then  
        echo "Lỗi: Không tồn tại phím tắt mô hình '$alias'."  
        exit 1  
    fi

    IFS='|' read \-r fullname window \<\<\< "$properties"

    echo "Đang khởi chạy Claude Code với cấu hình động..."  
    echo "Mô hình kích hoạt: $fullname"  
    echo "Cửa sổ thu gọn: $window tokens"

    \# Xuất biến môi trường hệ thống (Ghi đè hoàn toàn cấu hình tĩnh của settings.json)  
    export ANTHROPIC\_BASE\_URL="$NINE\_ROUTER\_URL"  
    export ANTHROPIC\_AUTH\_TOKEN="$NINE\_ROUTER\_TOKEN"  
    export ANTHROPIC\_MODEL="$fullname"  
    export ANTHROPIC\_DEFAULT\_OPUS\_MODEL="$fullname"  
    export ANTHROPIC\_DEFAULT\_SONNET\_MODEL="$fullname"  
    export ANTHROPIC\_DEFAULT\_HAIKU\_MODEL="$fullname"  
    export CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW="$window"

    claude "${extra\_args\[@\]}"  
}

set\_default() {  
    local alias\="$1"  
    local properties=$(get\_model\_properties "$alias")  
    if \[ "$properties" \== "INVALID" \]; then  
        echo "Lỗi: Phím tắt không hợp lệ."  
        exit 1  
    fi  
    IFS='|' read \-r fullname window \<\<\< "$properties"  
    write\_claude\_settings\_json "$fullname" "$window"  
    echo "Đã đặt mô hình mặc định tĩnh trong tệp cấu hình thành công."  
}

auto\_pilot() {  
    local requirement="$1"  
    if \[ \-z "$requirement" \]; then  
        echo "Lỗi: Yêu cầu thực thi trống."  
        exit 1  
    fi

    local plan\_file="CLAUDE\_PLAN.md"

    echo "================================================================================"  
    echo "GIAI ĐOẠN 1: THIẾT LẬP KẾ HOẠCH CHI TIẾT (Sử dụng Claude Fable 5)"  
    echo "================================================================================"  
      
    \# Thiết lập biến môi trường chạy Fable 5  
    export ANTHROPIC\_BASE\_URL="$NINE\_ROUTER\_URL"  
    export ANTHROPIC\_AUTH\_TOKEN="$NINE\_ROUTER\_TOKEN"  
    export ANTHROPIC\_MODEL="cc/fable-5"  
    export CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW="200000"

    local plan\_prompt="Bạn là một kỹ sư kiến trúc phần mềm bậc cao. Hãy phân tích yêu cầu sau, khảo sát cấu trúc dự án hiện tại, và lập kế hoạch triển khai chi tiết từng bước. Hãy ghi toàn bộ nội dung kế hoạch kiến trúc này vào tệp tin '$plan\_file'. Tuyệt đối không tự viết mã nguồn hay sửa đổi bất kỳ tệp tin nào khác trong giai đoạn này. Yêu cầu nhiệm vụ: $requirement"  
      
    \# Khởi chạy không tương tác, tự động cấp quyền ghi file kế hoạch  
    claude \-p "$plan\_prompt" \--dangerously-skip-permissions

    if \[ \! \-f "$plan\_file" \]; then  
        echo "Lỗi nghiêm trọng: Tệp tin kế hoạch '$plan\_file' chưa được tạo lập."  
        exit 1  
    fi  
    echo "Giai đoạn 1 thành công. Tệp kế hoạch đã được ghi nhận tại: $plan\_file"

    echo "================================================================================"  
    echo "GIAI ĐOẠN 2: THỰC THI KHÔNG GIÁM SÁT (Sử dụng MiniMax M3 \- 1M Context)"  
    echo "================================================================================"  
      
    \# Thiết lập cấu hình chạy MiniMax M3  
    export ANTHROPIC\_MODEL="minimax/MiniMax-M3"  
    export CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW="1000000"

    local exec\_prompt="Bạn là một chuyên gia lập trình thực thi. Hãy đọc toàn bộ tài liệu hướng dẫn và kế hoạch chi tiết trong tệp '$plan\_file'. Hãy thực hiện chính xác và đầy đủ từng bước một trong kế hoạch đó: viết mã nguồn mới, sửa đổi mã nguồn cũ, chạy thử nghiệm hệ thống, phân tích lỗi biên dịch và tự động sửa đổi cho đến khi hoàn thành triệt để mục tiêu."  
      
    \# Thực thi headless không can thiệp, tự động bypass mọi xác nhận để chạy qua đêm  
    claude \-p "$exec\_prompt" \--dangerously-skip-permissions

    echo "================================================================================"  
    echo "QUY TRÌNH AUTO-PILOT ĐÃ HOÀN THÀNH HOÀN TOÀN"  
    echo "================================================================================"  
}

\# Điều hướng tham số dòng lệnh  
case "$1" in  
    setup)       setup\_9router ;;  
    list)        list\_models ;;  
    run)         shift; run\_session "$@" ;;  
    set-default) set\_default "$2" ;;  
    auto-pilot)  auto\_pilot "$2" ;;  
    \*)           show\_help ;;  
esac

### **Kịch Bản PowerShell CLI (9cc.ps1) \- Dành Cho Môi Trường Windows Native**

Kịch bản PowerShell này giải quyết triệt để bài toán tương thích trên hệ điều hành Windows mà không cần cài đặt môi trường giả lập Linux14.

PowerShell  
\# \==============================================================================  
\# Lệnh quản lý mô hình Claude Code kết hợp cổng LLM Gateway 9Router  
\# Hỗ trợ: Windows (PowerShell native)  
\# \==============================================================================

$UserProfile \= \[System.Environment\]::GetFolderPath('UserProfile')  
$CLAUDE\_CONFIG\_DIR \= Join-Path $UserProfile ".claude"  
$CLAUDE\_CONFIG\_FILE \= Join-Path $CLAUDE\_CONFIG\_DIR "settings.json"  
$CONFIG\_ENV\_DIR \= Join-Path $UserProfile ".config\\9cc"  
$CONFIG\_ENV\_FILE \= Join-Path $CONFIG\_ENV\_DIR "9cc.env"

\# Khởi tạo các thư mục cấu hình mặc định  
if (\!(Test-Path $CLAUDE\_CONFIG\_DIR)) { New-Item \-ItemType Directory \-Path $CLAUDE\_CONFIG\_DIR \-Force | Out-Null }  
if (\!(Test-Path $CONFIG\_ENV\_DIR)) { New-Item \-ItemType Directory \-Path $CONFIG\_ENV\_DIR \-Force | Out-Null }

$NINE\_ROUTER\_URL \= "http://localhost:20128/v1"  
$NINE\_ROUTER\_TOKEN \= "default\_9router\_api\_key"

\# Nạp dữ liệu cấu hình lưu trữ  
if (Test-Path $CONFIG\_ENV\_FILE) {  
    Get-Content $CONFIG\_ENV\_FILE | ForEach-Object {  
        if ($\_ \-match "NINE\_ROUTER\_URL=(.\*)") { $global:NINE\_ROUTER\_URL \= $Matches\[1\].Trim('"') }  
        if ($\_ \-match "NINE\_ROUTER\_TOKEN=(.\*)") { $global:NINE\_ROUTER\_TOKEN \= $Matches\[1\].Trim('"') }  
    }  
} else {  
    "NINE\_ROUTER\_URL=""$NINE\_ROUTER\_URL""" | Out-File $CONFIG\_ENV\_FILE \-Encoding utf8  
    "NINE\_ROUTER\_TOKEN=""$NINE\_ROUTER\_TOKEN""" | Out-File $CONFIG\_ENV\_FILE \-Append \-Encoding utf8  
}

\# Bản đồ dữ liệu mô hình hỗ trợ  
$ModelMap \= @{  
    "fable"        \= @{ Name \= "cc/fable-5"; Window \= "200000" }  
    "opus"         \= @{ Name \= "cc/claude-opus-4-8"; Window \= "200000" }  
    "sonnet"       \= @{ Name \= "cc/claude-sonnet-5"; Window \= "200000" }  
    "haiku"        \= @{ Name \= "cc/claude-haiku-4-5-20251001"; Window \= "200000" }  
    "gpt5"         \= @{ Name \= "cx/gpt-5.5"; Window \= "128000" }  
    "glm5"         \= @{ Name \= "glm/glm-5.2"; Window \= "1000000" }  
    "glmturbo"     \= @{ Name \= "glm/glm-5-turbo"; Window \= "1000000" }  
    "deepseek"     \= @{ Name \= "ds/deepseek-v4-pro"; Window \= "1000000" }  
    "dsflash"      \= @{ Name \= "ds/deepseek-v4-flash"; Window \= "1000000" }  
    "kimi"         \= @{ Name \= "kimi/kimi-k2.7"; Window \= "1000000" }  
    "grok"         \= @{ Name \= "gc/grok-build"; Window \= "500000" }  
    "grokcomposer" \= @{ Name \= "gc/grok-composer-2.5-fast"; Window \= "500000" }  
    "minimax"      \= @{ Name \= "minimax/MiniMax-M3"; Window \= "1000000" }  
}

function Write-ClaudeSettings {  
    param ($defaultModel, $compactSize)  
      
    $settings \= @{  
        "model" \= $defaultModel  
        "availableModels" \= @(  
            "cc/fable-5", "cc/claude-opus-4-8", "cc/claude-sonnet-5", "cc/claude-haiku-4-5-20251001",  
            "cx/gpt-5.5", "glm/glm-5.2", "glm/glm-5-turbo", "ds/deepseek-v4-pro", "ds/deepseek-v4-flash",  
            "kimi/kimi-k2.7", "gc/grok-build", "gc/grok-composer-2.5-fast", "minimax/MiniMax-M3"  
        )  
        "modelOverrides" \= @{  
            "claude-opus-4-6" \= "cc/claude-opus-4-8"  
            "claude-sonnet-4-6" \= "cc/claude-sonnet-5"  
            "claude-haiku-4-5-20251001" \= "cc/claude-haiku-4-5-20251001"  
        }  
        "env" \= @{  
            "ANTHROPIC\_BASE\_URL" \= $global:NINE\_ROUTER\_URL  
            "ANTHROPIC\_AUTH\_TOKEN" \= $global:NINE\_ROUTER\_TOKEN  
            "CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW" \= $compactSize  
        }  
    }  
      
    $settings | ConvertTo-Json \-Depth 10 | Out-File $CLAUDE\_CONFIG\_FILE \-Encoding utf8  
}

function Show-Help {  
    Write-Host "\`nHệ thống Điều phối Đa Mô hình Claude Code qua 9Router (9cc.ps1)" \-ForegroundColor Green  
    Write-Host "\`nCách sử dụng:"  
    Write-Host "  .\\9cc.ps1 setup                     Cấu hình kết nối 9Router"  
    Write-Host "  .\\9cc.ps1 list                      Hiển thị danh sách các mô hình hỗ trợ"  
    Write-Host "  .\\9cc.ps1 run \<alias\> \[args...\]     Chạy phiên Claude Code với cấu hình động"  
    Write-Host "  .\\9cc.ps1 set-default \<alias\>       Đặt mô hình mặc định vào tệp tĩnh settings.json"  
    Write-Host "  .\\9cc.ps1 auto-pilot \<yêu\_cầu\>      Quy trình tự động hóa lập kế hoạch và triển khai qua đêm"  
}

if ($args.Count \-eq 0) {  
    Show-Help  
    exit  
}

switch ($args\[0\]) {  
    "setup" {  
        $inputUrl \= Read-Host "Nhập URL endpoint 9Router \[$global:NINE\_ROUTER\_URL\]"  
        if ($inputUrl) { $global:NINE\_ROUTER\_URL \= $inputUrl }  
          
        $inputToken \= Read-Host "Nhập API Key của 9Router \[$global:NINE\_ROUTER\_TOKEN\]"  
        if ($inputToken) { $global:NINE\_ROUTER\_TOKEN \= $inputToken }

        "NINE\_ROUTER\_URL=""$global:NINE\_ROUTER\_URL""" | Out-File $CONFIG\_ENV\_FILE \-Encoding utf8  
        "NINE\_ROUTER\_TOKEN=""$global:NINE\_ROUTER\_TOKEN""" | Out-File $CONFIG\_ENV\_FILE \-Append \-Encoding utf8

        Write-ClaudeSettings "cc/claude-sonnet-5" "1000000"  
        Write-Host "Đã khởi tạo thành công cấu hình hệ thống\!" \-ForegroundColor Green  
    }  
      
    "list" {  
        Write-Host "Phím tắt\`t|\`tMã định danh 9Router\`t\`t\`t|\`tCửa sổ nén mặc định" \-ForegroundColor Yellow  
        Write-Host "------------------------------------------------------------------------"  
        foreach ($key in $ModelMap.Keys) {  
            $val \= $ModelMap\[$key\]  
            Write-Host "$key\`t\`t|\`t$($val.Name.PadRight(25))\`t|\`t$($val.Window)"  
        }  
    }

    "run" {  
        if ($args.Count \-lt 2) {  
            Write-Error "Yêu cầu cung cấp phím tắt mô hình cần chạy."  
            exit  
        }  
        $alias \= $args\[1\]  
        if (\!$ModelMap.ContainsKey($alias)) {  
            Write-Error "Phím tắt '$alias' không tồn tại trên hệ thống."  
            exit  
        }  
        $model \= $ModelMap\[$alias\]  
        $extraArgs \= $args\[2..($args.Count\-1)\]

        \# Thiết lập biến môi trường cục bộ cho luồng thực thi PowerShell hiện tại  
        $env:ANTHROPIC\_BASE\_URL \= $global:NINE\_ROUTER\_URL  
        $env:ANTHROPIC\_AUTH\_TOKEN \= $global:NINE\_ROUTER\_TOKEN  
        $env:ANTHROPIC\_MODEL \= $model.Name  
        $env:ANTHROPIC\_DEFAULT\_OPUS\_MODEL \= $model.Name  
        $env:ANTHROPIC\_DEFAULT\_SONNET\_MODEL \= $model.Name  
        $env:ANTHROPIC\_DEFAULT\_HAIKU\_MODEL \= $model.Name  
        $env:CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW \= $model.Window

        Write-Host "Đang khởi động Claude Code sử dụng $($model.Name)..." \-ForegroundColor Cyan  
        if ($extraArgs) {  
            & claude $extraArgs  
        } else {  
            & claude  
        }  
    }

    "set-default" {  
        if ($args.Count \-lt 2) {  
            Write-Error "Yêu cầu cung cấp phím tắt mô hình."  
            exit  
        }  
        $alias \= $args\[1\]  
        if (\!$ModelMap.ContainsKey($alias)) {  
            Write-Error "Phím tắt không hợp lệ."  
            exit  
        }  
        $model \= $ModelMap\[$alias\]  
        Write-ClaudeSettings $model.Name $model.Window  
        Write-Host "Thiết lập mô hình mặc định '$($model.Name)' thành công." \-ForegroundColor Green  
    }

    "auto-pilot" {  
        if ($args.Count \-lt 2) {  
            Write-Error "Yêu cầu cung cấp nội dung mô tả nhiệm vụ."  
            exit  
        }  
        $requirement \= $args\[1\]  
        $plan\_file \= "CLAUDE\_PLAN.md"

        Write-Host "\`n=== GIAI ĐOẠN 1: THIẾT LẬP KẾ HOẠCH (Claude Fable 5\) \===" \-ForegroundColor Yellow  
        $env:ANTHROPIC\_BASE\_URL \= $global:NINE\_ROUTER\_URL  
        $env:ANTHROPIC\_AUTH\_TOKEN \= $global:NINE\_ROUTER\_TOKEN  
        $env:ANTHROPIC\_MODEL \= "cc/fable-5"  
        $env:CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW \= "200000"

        $plan\_prompt \= "Bạn là một kỹ sư kiến trúc phần mềm bậc cao. Hãy phân tích yêu cầu sau, khảo sát cấu trúc dự án hiện tại, và lập kế hoạch triển khai chi tiết từng bước. Hãy ghi toàn bộ nội dung kế hoạch kiến trúc này vào tệp tin '$plan\_file'. Tuyệt đối không tự viết mã nguồn hay sửa đổi bất kỳ tệp tin nào khác trong giai đoạn này. Yêu cầu nhiệm vụ: $requirement"  
        & claude \-p $plan\_prompt \-\-dangerously-skip-permissions

        if (\!(Test-Path $plan\_file)) {  
            Write-Error "Lỗi: Không tìm thấy tệp kế hoạch '$plan\_file' được sinh ra."  
            exit  
        }

        Write-Host "\`n=== GIAI ĐOẠN 2: THỰC THI KHÔNG GIÁM SÁT (MiniMax M3) \===" \-ForegroundColor Yellow  
        $env:ANTHROPIC\_MODEL \= "minimax/MiniMax-M3"  
        $env:CLAUDE\_CODE\_AUTO\_COMPACT\_WINDOW \= "1000000"

        $exec\_prompt \= "Đọc tài liệu kế hoạch lập trình chi tiết tại file '$plan\_file'. Hãy thực hiện chính xác và đầy đủ các bước đã được vạch ra trong tài liệu này. Viết code, chạy thử nghiệm, sửa các lỗi biên dịch nếu có. Hoàn thành toàn bộ kế hoạch một cách triệt để."  
        & claude \-p $exec\_prompt \-\-dangerously-skip-permissions

        Write-Host "\`n=== QUY TRÌNH HỆ THỐNG ĐÃ HOÀN TẤT TRIỆT ĐỂ \===" \-ForegroundColor Green  
    }

    Default {  
        Show-Help  
    }  
}

## **4\. Phân Tích Rủi Ro Và Cơ Chế Bảo Vệ Khi Vận Hành headless Tự Động Qua Đêm**

Việc vận hành các mô hình thực thi tự động qua đêm mà không có sự giám sát của kỹ sư (Headless Execution) mang đến rủi ro đáng kể đối với hệ thống máy chủ và mã nguồn thực tế của dự án26. Khi cờ bỏ qua xác thực quyền \--dangerously-skip-permissions được kích hoạt, hệ thống an toàn đa tầng của Claude Code bị vô hiệu hóa hoàn toàn26:

* **Vô hiệu hóa bộ lọc lệnh nguy hiểm:** Các lệnh tải tài nguyên hoặc can thiệp sâu hệ thống (như curl, wget, ssh) vốn bị chặn ở chế độ thông thường sẽ được tự do hoạt động26.  
* **Nguy cơ rò rỉ mã khóa bí mật:** Các mã độc chèn gián tiếp thông qua lỗi bảo mật Prompt Injection trong các tài liệu tải về có thể điều hướng mô hình đọc và gửi các tệp cấu hình chứa mã mật (.env, SSH keys) tới endpoint ngoài27.  
* **Lỗi phá hoại hệ thống tệp tin ngoài ý muốn:** Lỗi phân tích cú pháp ký tự đặc biệt của shell có thể dẫn tới việc xóa nhầm các dữ liệu quan trọng nằm ngoài phạm vi thư mục làm việc (như sự cố hệ thống tự động sinh lệnh xóa rm \-rf \~/ khét tiếng)26.

Để triệt tiêu hoàn toàn các nguy hại này khi chạy tự động hóa lúc ngủ, việc xây dựng một kiến trúc bảo mật cô lập đa lớp là điều bắt buộc27:

| Lớp bảo mật thiết yếu | Biện pháp triển khai cụ thể trong dự án | Mục tiêu ngăn chặn rủi ro |
| :---- | :---- | :---- |
| **Cô lập thùng chứa ảo (Container Sandbox)** | Chạy Claude Code độc lập hoàn toàn bên trong Container Docker (như giải pháp claude-pod)29. Chỉ ánh xạ (bind-mount) duy nhất thư mục mã nguồn dự án hiện hành vào container29. | Ngăn chặn tuyệt đối khả năng tác nhân AI truy cập, đọc hoặc xóa các dữ liệu nhạy cảm trong thư mục cá nhân hay các khóa SSH của máy chủ vật lý27. |
| **Chốt chặn phân nhánh Git (Git Sandboxing)** | Trước khi kích hoạt lệnh chạy tự động qua đêm, bắt buộc thực hiện kiểm tra và đưa toàn bộ mã nguồn hiện tại về trạng thái sạch sẽ26. Chạy tác vụ tự động trên một nhánh phát triển biệt lập (feature/auto-codegen)27. | Khi có sự cố mô hình viết lỗi cấu trúc hoặc sinh mã nguồn phá hoại hệ thống, kỹ sư chỉ cần thực hiện lệnh khôi phục trạng thái cũ một cách đơn giản thông qua lệnh git reset \--hard27. |
| **Kiểm soát kết nối mạng (Egress Network Control)** | Áp dụng chính sách mạng chặn toàn bộ (Default Deny) trên Container thực thi27. Chỉ mở kết nối outbound tới các địa chỉ được khai báo tường minh trong danh sách trắng (như IP VPS của 9Router và các kho lưu trữ gói thư viện chính thức như npmjs)27. | Triệt tiêu hoàn toàn nguy cơ rò rỉ dữ liệu hoặc mã khóa cấu mật ra ngoài thông qua các lỗ hổng tiêm mã độc (Prompt Injection)27. |
| **Cảnh báo và quản lý hạn mức (Quota Management)** | Cấu hình giới hạn chi phí hàng ngày (Daily Spending Budget) trực tiếp trên trang quản trị dự án của các nhà cung cấp hoặc trong dashboard của 9Router8. | Ngăn chặn hiện tượng rò rỉ tài chính do tác nhân AI rơi vào trạng thái vòng lặp vô hạn (infinite retry loops) khi sửa lỗi biên dịch không thành công13. |

Áp dụng đúng các biện pháp kỹ thuật cô lập này sẽ giúp đội ngũ tối ưu hóa toàn bộ hiệu suất lập trình tự động, vận hành hệ thống bền vững 24/7 và chuyển đổi linh hoạt giữa các dòng mô hình AI một cách tuyệt đối an toàn8.

#### **Nguồn trích dẫn**

1. I finally got multi-model switching to work with Claude | by Sujith K. Surendran | Medium, [https://medium.com/@itssujeeth/i-finally-got-multi-model-switching-to-work-with-claude-7f6da489b278](https://medium.com/@itssujeeth/i-finally-got-multi-model-switching-to-work-with-claude-7f6da489b278)  
2. Overview \- Z.AI DEVELOPER DOCUMENT, [https://docs.z.ai/devpack/overview](https://docs.z.ai/devpack/overview)  
3. Claude Code \- Overview \- Z.AI DEVELOPER DOCUMENT, [https://docs.z.ai/devpack/tool/claude](https://docs.z.ai/devpack/tool/claude)  
4. Your First Conversations \- Cheatsheet | SFEIR Institute, [https://institute.sfeir.com/en/claude-code/claude-code-your-first-conversations/cheatsheet/](https://institute.sfeir.com/en/claude-code/claude-code-your-first-conversations/cheatsheet/)  
5. Model configuration \- Claude Code Docs, [https://code.claude.com/docs/en/model-config](https://code.claude.com/docs/en/model-config)  
6. Model setting changes globally across all sessions (regression) · Issue \#20745 · anthropics/claude-code \- GitHub, [https://github.com/anthropics/claude-code/issues/20745](https://github.com/anthropics/claude-code/issues/20745)  
7. Hướng dẫn cài đặt và kết nối 9Router với OpenClaw, Hermes AI agent để sử dụng LLM miễn phí \- TOTHOST, [https://tothost.vn/huong-dan-su-dung/huong-dan-cai-dat-va-ket-noi-9router-voi-openclaw-hermes-ai-agent-de-su-dung-llm-mien-phi](https://tothost.vn/huong-dan-su-dung/huong-dan-cai-dat-va-ket-noi-9router-voi-openclaw-hermes-ai-agent-de-su-dung-llm-mien-phi)  
8. 9Router là gì? \- LLM Gateway hoàn hảo cho AI coding tools? \- Viblo.asia, [https://viblo.asia/p/9router-la-gi-llm-gateway-hoan-hao-cho-ai-coding-tools-gjLN0MRW432](https://viblo.asia/p/9router-la-gi-llm-gateway-hoan-hao-cho-ai-coding-tools-gjLN0MRW432)  
9. 9router \- AI Agents on GitHub (20.4k ) | SkillsLLM, [https://skillsllm.com/skill/9router](https://skillsllm.com/skill/9router)  
10. Integrate with Claude Code | DeepSeek API Docs, [https://api-docs.deepseek.com/quick\_start/agent\_integrations/claude\_code](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code)  
11. Integrate with Claude Code | DeepSeek API Docs, [https://api-docs.deepseek.com/guides/agent\_integrations/claude\_code](https://api-docs.deepseek.com/guides/agent_integrations/claude_code)  
12. How to Switch Models \- Overview \- Z.AI DEVELOPER DOCUMENT, [https://docs.z.ai/devpack/latest-model](https://docs.z.ai/devpack/latest-model)  
13. Use Kimi K2.7 Code Model in ClaudeCode/Cline/RooCode, [https://platform.kimi.ai/docs/guide/agent-support](https://platform.kimi.ai/docs/guide/agent-support)  
14. Use Kimi in Claude Code, [https://platform.kimi.ai/docs/guide/claude-code-kimi](https://platform.kimi.ai/docs/guide/claude-code-kimi)  
15. Claude Code \- Models \- MiniMax API Docs, [https://platform.minimax.io/docs/token-plan/claude-code](https://platform.minimax.io/docs/token-plan/claude-code)  
16. Token Plan Overview \- Models \- MiniMax API Docs, [https://platform.minimax.io/docs/token-plan/intro](https://platform.minimax.io/docs/token-plan/intro)  
17. Environment variables \- Claude Code Docs, [https://code.claude.com/docs/en/env-vars](https://code.claude.com/docs/en/env-vars)  
18. Claude Code Operator's Handbook | hidekazu-konishi.com, [https://hidekazu-konishi.com/entry/claude\_code\_operators\_handbook.html](https://hidekazu-konishi.com/entry/claude_code_operators_handbook.html)  
19. Claude Code CLI: The Complete Guide — Hooks, MCP, Skills \- Blake Crosley, [https://blakecrosley.com/guides/claude-code](https://blakecrosley.com/guides/claude-code)  
20. Choose a permission mode \- Claude Code Docs, [https://code.claude.com/docs/en/permission-modes](https://code.claude.com/docs/en/permission-modes)  
21. Claude Code settings.json : r/ClaudeAI \- Reddit, [https://www.reddit.com/r/ClaudeAI/comments/1l24a93/claude\_code\_settingsjson/](https://www.reddit.com/r/ClaudeAI/comments/1l24a93/claude_code_settingsjson/)  
22. Claude Code settings \- Claude Code Docs, [https://code.claude.com/docs/en/settings](https://code.claude.com/docs/en/settings)  
23. Claude Code Settings Deep Dive \- ClaudePluginHub, [https://www.claudepluginhub.com/skills/markus41-claude-code-expert-plugins-claude-code-expert/settings-deep-dive](https://www.claudepluginhub.com/skills/markus41-claude-code-expert-plugins-claude-code-expert/settings-deep-dive)  
24. 9Router download | SourceForge.net, [https://sourceforge.net/projects/ninerouter.mirror/](https://sourceforge.net/projects/ninerouter.mirror/)  
25. Interactive mode \- Claude Code Docs, [https://code.claude.com/docs/en/interactive-mode](https://code.claude.com/docs/en/interactive-mode)  
26. claude \--dangerously-skip-permissions \- TND, [https://www.tnd.vn/claude-dangerously-skip-permissions-11940/](https://www.tnd.vn/claude-dangerously-skip-permissions-11940/)  
27. Claude Code \--dangerously-skip-permissions: What It Does and When Not to Use It, [https://www.truefoundry.com/blog/claude-code-dangerously-skip-permissions](https://www.truefoundry.com/blog/claude-code-dangerously-skip-permissions)  
28. Claude Code dangerously-skip-permissions: Why It's Tempting, Why It's Dangerous, [https://thomas-wiegold.com/blog/claude-code-dangerously-skip-permissions/](https://thomas-wiegold.com/blog/claude-code-dangerously-skip-permissions/)  
29. Run Claude Code's \--dangerously-skip-permissions Safely with Docker \- DEV Community, [https://dev.to/trekhleb/run-claude-codes-dangerously-skip-permissions-safely-with-docker-514d](https://dev.to/trekhleb/run-claude-codes-dangerously-skip-permissions-safely-with-docker-514d)