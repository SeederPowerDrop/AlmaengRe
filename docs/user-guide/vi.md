<!-- almeng-guide-source-sha256: 9ad0336ec7c87dc7d9724642c55ccfc227e2f07336711386ef1d14f94fd40248 -->

<a name="top"></a>

# Hướng dẫn sử dụng 알맹Re

[한국어](ko.md) · [English](en.md) · [日本語](ja.md) · [简体中文](zh-Hans.md) · [Français](fr.md) · [Español](es.md) · [Tiếng Việt](vi.md)

[← 알맹Re](../../README.md) · [PDF](pdf/AlmaengRe-User-Guide-vi.pdf)

**Mở, xem, so sánh, phân loại và chỉnh sửa ảnh trên Mac**

Hướng dẫn thực hành cho phiên bản phát triển 0.13.1 hiện tại. Hãy bắt đầu bằng một thư mục ảnh, rồi tra cứu chương phù hợp với việc bạn muốn làm. Tên menu trong hướng dẫn theo giao diện tiếng Việt của ứng dụng.

Phiên bản 0.13.1 · Tính đến 2026-10-10

> Ảnh chụp màn hình lấy từ ứng dụng thật với giao diện tiếng Hàn và ảnh minh họa được tạo riêng. Các chú thích đánh số và phần giải thích được dịch sang ngôn ngữ của hướng dẫn; nội dung ảnh chụp màn hình giữ nguyên. Không sử dụng bộ sưu tập ảnh cá nhân.

## Mục lục

- [1. Mở ảnh, thư mục và tệp ZIP](#open)
- [2. Duyệt ảnh và xem tập trung](#viewer)
- [3. Tìm và chọn ảnh trong Xem tất cả](#overview)
- [4. So sánh hai bộ ảnh](#compare)
- [5. Gắn nhãn ảnh và video](#tags)
- [6. Đặt tên, màu nhãn và hiểu giới hạn theo dõi ảnh](#tag-editor)
- [7. Tìm ảnh theo vị trí](#map)
- [8. Xem thông tin ảnh và siêu dữ liệu](#information)
- [9. Chỉnh sửa ảnh và xuất bản sao](#editing)
- [10. Đổi tên, chuyển đổi, thu nhỏ và chia sẻ nhiều ảnh](#batch)
- [11. Thêm dấu chìm bằng chữ, EXIF và logo](#watermark)
- [12. Phát video, trích xuất khung hình và lưu đoạn phim](#video)
- [13. Duyệt và lưu các khung hình của ảnh động](#animation)
- [14. Phóng to và so sánh kết quả AI](#ai-upscaling)
- [15. Hiểu chất lượng hiển thị, HDR và tải ảnh](#quality)
- [16. Phát album ảnh hoặc đặt hình nền](#slideshow)
- [17. Thiết lập theo cách làm việc của bạn](#settings)
- [18. Phím tắt và xử lý nhanh vấn đề](#shortcuts)
- [Bảng phím tắt](#shortcut-reference)

---

<a name="open"></a>

## 1. Mở ảnh, thư mục và tệp ZIP

Dùng Mở… cho ảnh, video, thư mục và ZIP. Ảnh và video được hỗ trợ mặc định hiển thị cùng nhau; ZIP chỉ hỗ trợ ảnh.

![Trang chủ gồm biểu tượng ứng dụng, nút mở và ảnh đã xem gần đây.](figures/home.png)

**Màn hình 01.** Trang chủ gồm biểu tượng ứng dụng, nút mở và ảnh đã xem gần đây.

1. **Mở hoặc tiếp tục** — Dùng Mở… để mở bộ ảnh mới hoặc Tiếp tục phiên trước để trở lại công việc đã lưu.
2. **Bảy ảnh gần đây** — Tối đa bảy ảnh đã xem trong Trình xem hoặc So sánh ảnh, ảnh xem gần nhất trước; bấm để mở lại. Gồm ảnh thường, GIF và ảnh trong ZIP; không gồm video.
3. **Xóa lịch sử gần đây** — Xóa khỏi danh sách cho từng ảnh hoặc Xóa danh sách chỉ xóa lịch sử, không xóa tệp gốc. Xem lại một ảnh có thể đưa ảnh đó trở lại danh sách.

### Các bước thực hiện

1. Chạy 알맹Re trên macOS 14 trở lên để vào Trang chủ. Dùng Mở… (⌘O) hoặc bấm ảnh gần đây. Mở… cũng có trên thanh công cụ và menu Tệp.
2. Chọn thư mục để duyệt nội dung. Mở một ảnh để xem tiếp trong cùng thư mục; chọn nhiều tệp chỉ mở những tệp đó. Hiển thị video mặc định bật và ghi nhớ lựa chọn. Mở trực tiếp video cũng bật tùy chọn này.
3. Chọn tệp ZIP để xem các ảnh được hỗ trợ, kể cả ảnh trong thư mục con của tệp nén. Bạn cũng có thể mở tệp từ Finder hoặc kéo ảnh và thư mục vào ứng dụng.

### Thư mục và mục yêu thích

Cây thư mục mở rộng từng thư mục khi cần. Bấm tên thư mục để mở, dùng mũi tên lên để về thư mục cha và làm mới sau khi thay đổi trong Finder. Ghim một thư mục phía trên cây để truy cập nhanh. Mở thư mục thông thường không tự động bao gồm mọi thư mục con.

### ZIP chỉ để đọc

Ảnh được giải nén vào thư mục tạm trong lúc tệp ZIP đang mở. Hãy xuất bản sao trước khi đổi tên hoặc sửa siêu dữ liệu gốc. Ứng dụng không ghi lại tệp ZIP. Hỗ trợ phương thức Stored/Deflate; không mở tệp nén mã hóa hoặc dùng phương thức khác. Giới hạn gồm tệp ZIP 2 GiB, 10.000 mục, 256 MiB cho mỗi mục sau giải nén và tổng dữ liệu giải nén 1 GiB. Không hỗ trợ video bên trong tệp ZIP.

### Trang chủ và phiên trước

Khi mở bình thường, ứng dụng hiển thị Trang chủ. Tiếp tục phiên trước khôi phục bộ ảnh, lựa chọn, chế độ xem và tìm kiếm khi có thể. Trang chủ trên thanh công cụ hoặc menu giữ nguyên công việc hiện tại. Tệp mở từ Finder được hiển thị ngay. Nếu kết nối hoặc quyền thay đổi, dùng Mở… lần nữa. Các chỉnh sửa và kết quả AI chưa lưu không được khôi phục khi mở lại ứng dụng.

### Điều cần biết

- Chọn thư mục cùng với các ảnh riêng lẻ sẽ tập hợp chúng mà không trùng lặp. Trong So sánh ảnh, Mở… thay đổi khung A hoặc B đang hoạt động và không bị khóa. Trợ giúp → Cách sử dụng cơ bản mở hướng dẫn ngắn ngay trong ứng dụng. Trợ giúp → Hướng dẫn chi tiết (GitHub) mở bản hướng dẫn đầy đủ theo ngôn ngữ của bạn trên GitHub bằng trình duyệt mặc định.

[Về đầu trang](#top)

---

<a name="viewer"></a>

## 2. Duyệt ảnh và xem tập trung

Trình xem có thể hiển thị từ một đến mười ảnh cùng lúc. Phóng to để kiểm tra chi tiết hoặc ẩn các điều khiển xung quanh để tập trung vào ảnh. Khi xem nhiều mục, video bắt đầu bằng ảnh tĩnh và phát tắt tiếng khi di chuột lên.

![Trình xem hiển thị nhiều ảnh và video cùng nhau. Di chuột lên video để xem trước tắt tiếng.](figures/viewer.png)

**Màn hình 02.** Trình xem hiển thị nhiều ảnh và video cùng nhau. Di chuột lên video để xem trước tắt tiếng.

1. **Chế độ xem** — Chuyển giữa Trình xem, Xem tất cả, Xem bản đồ và So sánh ảnh.
2. **Tìm kiếm, bộ lọc và video** — Chỉnh tìm kiếm, định dạng, nhãn, sắp xếp và Hiển thị video cho danh sách hiện tại.
3. **Điều khiển xem** — Duyệt các mục và đổi số mục hiển thị. Chỉnh mức thu phóng và cách di chuyển ảnh.

### Các bước thực hiện

1. Chọn Trình xem ở phía trên. Dùng ← và → để chuyển ảnh. Đặt số ảnh mỗi màn hình bằng điều khiển số lượng hoặc \[ và \]; lưới sẽ thích ứng với hình dạng cửa sổ.
2. Chụm hoặc mở hai ngón tay trên bàn di chuột, hay dùng = và − để thu phóng. Nhấn 0 để Vừa cửa sổ và 1 để Kích thước thực. Chọn cách di chuyển ảnh từ các điều khiển phía dưới hoặc Cài đặt → Chung.
3. Nhấn F, bấm đúp ảnh hoặc nhấn nhanh Space để bật/tắt chế độ tập trung. Nhấn Esc để quay lại. Toàn màn hình là lệnh riêng, dùng ⌃⌘F.

### Chuyển nhiều ảnh cùng lúc

Trong Trình xem, ←/→ chuyển theo số mục đã đặt cho mỗi trang, với Phân loại ON hay OFF. Khi hiển thị nhiều mục, ↑/↓ chọn hàng trên hoặc dưới trong trang hiện tại và dừng ở hàng đầu, hàng cuối. Nếu hàng cuối không đầy, thẻ hiện có gần nhất được chọn. ⌥←/⌥→ luôn chuyển cả trang, kể cả khi phân loại.

### Điều khiển di chuyển ảnh

Chọn kéo bằng nút trái, Space + kéo bằng nút trái, kéo bằng nút phải, nút giữa hoặc di chuyển bằng hai ngón tay trên bàn di chuột. Các phím ⌃⌥1–5 chọn cách di chuyển, không tự làm ảnh dịch chuyển. Vuốt ngang chuyển ảnh khi cử chỉ đó không được dùng để di chuyển ảnh phóng to. Khi di chuyển, kể cả lúc đang kéo, chỉ cho phép một khoảng nhỏ ở mép ảnh để ảnh không bị đẩy vào vùng trống lớn. Trục nhỏ hơn khung xem luôn được căn giữa; đổi mức thu phóng hoặc kích thước cửa sổ sẽ điều chỉnh lại giới hạn. Quy tắc này cũng áp dụng khi xem nhiều ảnh và so sánh chất lượng phóng to.

### Điều khiển trong chế độ tập trung

Dấu × phía dưới chỉ ẩn thanh điều khiển nổi. Mở lại bằng nút cạnh tên tệp. Dấu × phía trên thoát chế độ tập trung. Các nút này vẫn dùng được khi ẩn tên tệp. Nhấn nhanh Space không đổi chế độ khi đang nhập chữ hoặc khi Space được gán phím tắt riêng.

### Điều cần biết

- Ảnh thu nhỏ có thể nằm bên trái, phải, trên, dưới hoặc được ẩn. Esc thoát chế độ xem tạm thời hiện tại trước khi đưa Trình xem thông thường về Xem tất cả.

[Về đầu trang](#top)

---

<a name="overview"></a>

## 3. Tìm và chọn ảnh trong Xem tất cả

Xem tất cả trải bộ ảnh hiện tại thành lưới ảnh thu nhỏ. Dùng chế độ này để nhìn qua thư mục, chọn ảnh cần dùng và chuẩn bị thao tác hàng loạt. Video chỉ hiển thị ảnh xem trước tĩnh, không phát.

![Xem tất cả kết hợp lưới ảnh thu nhỏ với tìm kiếm, lựa chọn và điều chỉnh kích thước.](figures/overview.png)

**Màn hình 03.** Xem tất cả kết hợp lưới ảnh thu nhỏ với tìm kiếm, lựa chọn và điều chỉnh kích thước.

1. **Lưới ảnh thu nhỏ** — Bấm, chọn theo khoảng hoặc kéo để chọn thẻ. Video có bản xem trước tĩnh; bấm đúp để mở toàn màn hình.
2. **Tìm kiếm, bộ lọc và video** — Điều chỉnh tìm kiếm, sắp xếp, định dạng, nhãn và Hiển thị video cho danh sách hiện tại.
3. **Kích thước và lựa chọn** — Điều chỉnh ảnh xem trước và dùng các thao tác dành cho ảnh đã chọn để xử lý hàng loạt.

### Các bước thực hiện

1. Trong Xem tất cả (G), chỉnh cỡ ảnh thu nhỏ. Nhấp đúp để mở ảnh trong Trình xem hoặc video toàn màn hình.
2. Nhập vào Tìm theo tên tệp. Tìm kiếm không phân biệt chữ hoa/thường; mọi từ ngăn bằng dấu cách đều phải xuất hiện trong tên tệp. Chọn một hay nhiều định dạng, hoặc Tất cả định dạng để bỏ bộ lọc đó.
3. Bấm để chọn, ⌘-bấm để thêm hoặc bỏ, ⇧-bấm để chọn một khoảng. Kéo hình chữ nhật từ thẻ hoặc vùng trống để chọn các thẻ giao với vùng đó. Với Phân loại ON hay OFF, ←/→ chuyển từng thẻ và ↑/↓ chuyển từng hàng. Dừng ở hàng đầu và cuối; nếu hàng cuối không đầy, chọn thẻ hiện có gần nhất. Danh sách lọc theo bản đồ cũng tương tự. Khi OFF, phím tắt tùy chỉnh được ưu tiên.

### Phím hỗ trợ chọn ảnh

Giữ Shift khi bắt đầu kéo vùng chọn để thêm vào lựa chọn hiện có. Giữ ⌘ để đảo trạng thái chọn các ảnh trong vùng. Esc khôi phục lựa chọn trước khi kéo. ⌘A chọn mọi ảnh trong danh sách đang hiển thị.

### Sắp xếp danh sách hiện tại

Các nhóm Tên và tệp, Kích thước và thời điểm chụp, Máy ảnh và màu sắc, Vị trí gồm tên, ngày của tệp, dung lượng, GPS, chiều rộng, chiều cao, thời điểm chụp, loại tệp, tốc độ màn trập, hãng sản xuất, mẫu máy, khẩu độ và không gian màu. Tên theo thứ tự số tự nhiên; màn trập theo thời gian phơi sáng; khẩu độ theo số f. Giá trị thiếu luôn ở cuối ở cả hai chiều. Loại tệp theo phần mở rộng, gộp các cách viết JPEG/TIFF tương đương. Không đổi tệp gốc.

### Số thứ tự và kích thước xem trước

Nút # hiện hoặc ẩn số thứ tự ảnh thu nhỏ. Nhãn số quá lớn sẽ nằm ngoài ảnh nhỏ để không che ảnh. Kích thước ảnh thu nhỏ được ghi nhớ, với phạm vi 44,8–665,6 point; từng ô còn bị giới hạn bởi chiều rộng cửa sổ.

### Giới hạn sắp xếp theo thông tin chụp

Chiều rộng và cao là số pixel gốc theo hướng tệp, chưa áp dụng chỉnh sửa. Thời điểm chụp lấy từ EXIF hoặc ngày ghi trong video, không thay bằng ngày tạo tệp. Giờ EXIF không có múi giờ được coi là UTC khi sắp xếp. Video dùng kích thước, ngày, hãng, mẫu máy và màu đọc được; màn trập và khẩu độ coi là thiếu. Chỉ đọc dữ liệu khi chọn cách sắp xếp cần chúng rồi tái sử dụng, nên lần đầu có thể mất thời gian.

### Điều cần biết

- Tìm theo tên tệp, không theo nội dung hay OCR. Không có kết quả, điều khiển vẫn ở trên; dùng Đặt lại tìm kiếm và bộ lọc. Tệp không bị xóa. Tắt Ảnh chưa gắn nhãn và không chọn nhãn: không lọc theo nhãn.

[Về đầu trang](#top)

---

<a name="compare"></a>

## 4. So sánh hai bộ ảnh

So sánh ảnh giữ hai bộ A và B độc lập, đặt cạnh nhau hoặc trên dưới. Chế độ này phù hợp để so phiên bản hoặc kiểm tra hai thư mục.

![Hai bộ ảnh trong So sánh ảnh.](figures/compare.png)

**Màn hình 04.** Hai bộ ảnh trong So sánh ảnh.

1. **Khung A và B** — Dưới tên mỗi khung, xem phím nhãn đã chọn, điều kiện và số ảnh. Khi tắt Ảnh chưa gắn nhãn và không chọn nhãn nào, mọi ảnh đều được hiển thị; A/B có thể trùng ảnh. Nếu kết quả trống, kiểm tra nhãn và bộ lọc chung về tìm kiếm, định dạng, bản đồ. Xóa chỉ bỏ bộ lọc nhãn của khung đó.
2. **Cách so sánh** — Chọn cách ghép ảnh, bên cần chuyển, lặp bên ít ảnh hơn và liên kết thu phóng.
3. **Áp dụng nhãn** — Khi ON, chọn Chỉ A, Chỉ B hoặc Cả hai cho phím và nút bên dưới, độc lập với đối tượng chuyển ảnh. − nghĩa là chỉ một số ảnh có nhãn.

### Các bước thực hiện

1. So sánh ảnh hiện tại theo nhãn mở danh sách gốc trong A/B, giữ bộ lọc tìm kiếm, định dạng và vùng bản đồ. Chỉ A nhận bộ lọc nhãn thông thường; B bắt đầu với tất cả ảnh. Với thư mục khác, dùng So sánh ảnh (⌃⌥C), Chọn thư mục để so sánh… hoặc Mở… của từng khung.
2. Dùng nút nhãn dưới tên mỗi khung để chọn nhiều nhãn trong 12 nhãn hiện có, chẳng hạn A chọn 1·F, B chọn 3·Q·S. Mặc định là Có bất kỳ nhãn đã chọn nào (OR); cũng có thể dùng Có tất cả nhãn đã chọn (AND) hoặc Ảnh chưa gắn nhãn.
3. Trong Chuyển ảnh, chọn một bên theo tên hiển thị hoặc Cả hai. Dùng mũi tên chung hoặc ảnh thu nhỏ để chuyển. Bật Liên kết phóng to và di chuyển để xem các vị trí tương đối tương ứng. Mỗi khung cũng chỉ cho phép một khoảng nhỏ ở mép, căn giữa trục nhỏ hơn khung và điều chỉnh lại giới hạn khi đổi mức thu phóng hoặc kích thước cửa sổ.

### Chuyển ảnh và lặp

Duyệt kết quả đã lọc theo Thứ tự danh sách hoặc ghép bằng Tên tệp trùng khớp: 001.jpg khớp với 001.png; thiếu ảnh ghép sẽ để trống một bên. Chọn một bên sẽ về Thứ tự danh sách; Tên tệp trùng khớp chuyển theo cặp. Khi chọn Cả hai, Lặp bên ít ảnh hơn lặp danh sách ngắn từ đầu; khi tắt, giữ ảnh cuối. Lặp dùng cho Thứ tự danh sách.

### Đối tượng gắn nhãn và khóa

Khi Phân loại ON, Áp dụng nhãn chọn Chỉ A, Chỉ B hoặc Cả hai cho phím và nút bên dưới. Lựa chọn độc lập với khung hoạt động và đối tượng chuyển ảnh, mặc định Chỉ A và giữ trong phiên chạy ứng dụng. Cả hai hiện − khi chỉ một số ảnh có nhãn: nhấn để gắn cho cả hai, hoặc bỏ ở cả hai nếu đều đã có. Cùng một ảnh chỉ xử lý một lần. Mọi ảnh đích phải thực sự hiển thị; Cả hai bị vô hiệu nếu một bên trống hoặc đang tải. Vẫn có thể gắn nhãn cho ảnh bị khóa. Khóa giữ ảnh, thu phóng, vị trí và bộ lọc. Khóa B để chuyển A, hoặc A để chuyển B. Mở khóa cả hai đưa đối tượng chuyển ảnh về Cả hai; khóa cả hai dừng chuyển. Vẫn có thể xem và cuộn ảnh thu nhỏ bị khóa.

### Ảnh gốc và trạng thái đã lưu

So sánh hiển thị ảnh gốc chưa chỉnh sửa, không gồm video. Thoát để chỉnh sửa, xử lý hàng loạt hoặc đặt hình nền; Esc về chế độ trước. Bố trí, liên kết, chuyển ảnh, đầu vào/vị trí A/B và bộ lọc nhãn được khôi phục. Bộ lọc vẫn giữ khi mở đầu vào khác. Tên so sánh… đặt tên riêng tối đa 80 ký tự. Để trống hoặc Dùng tên tự động dùng tên thư mục/ZIP; Lưu áp dụng, Hủy giữ nguyên. Cùng thư mục/ZIP hay danh sách trộn dùng A/B; thư mục khác nhau trùng tên thêm (A)/(B). Tên riêng không đổi tên thư mục, vẫn giữ khi khởi động lại hoặc mở cùng đầu vào, chỉ đặt lại với đầu vào mới của khung đó. Trỏ vào tên rút gọn để đọc đầy đủ.

### Điều cần biết

- ⌥←/⌥→ chỉ chuyển A; ⇧⌥←/⇧⌥→ chỉ chuyển B. Tên tệp trùng khớp bỏ qua phần mở rộng, chữ hoa/thường và các cách biểu diễn Unicode tương đương.

[Về đầu trang](#top)

---

<a name="tags"></a>

## 5. Gắn nhãn ảnh và video

Gắn nhiều nhãn cho ảnh và video trong lúc duyệt. Chỉ Phân loại ON cho phép đổi nhãn; đây là dấu trong ứng dụng, không phải thao tác lên tệp gốc.

![Phân loại ON: phím và nút bên dưới cho mục hiện tại, cùng menu Nhãn riêng trên mỗi thẻ.](figures/tags.png)

**Màn hình 05.** Phân loại ON: phím và nút bên dưới cho mục hiện tại, cùng menu Nhãn riêng trên mỗi thẻ.

1. **Phân loại ON/OFF** — ON cho phép đổi nhãn; OFF khôi phục các phím xem thông thường.
2. **Phím và nút bên dưới** — Bật/tắt nhãn của mục hiện tại. Có thể gắn nhiều nhãn cùng lúc.
3. **Menu Nhãn trên mỗi thẻ** — Chỉ đổi ảnh hoặc video đó, không đổi lựa chọn hiện tại hay nhóm đang chọn.

### Các bước thực hiện

1. Dùng Phân loại ON/OFF, menu Nhãn ảnh hoặc ⌘⇧M. Bật ON kết thúc nhập tìm kiếm. Phím tác động lên mục hiện tại; trong so sánh, theo Chỉ A, Chỉ B hoặc Cả hai tại Áp dụng nhãn.
2. Khi ON, dùng vị trí phím 1–4, QWER, ASDF hoặc các nút bên dưới. Trong Trình xem và Xem tất cả, menu Nhãn trên mỗi thẻ chỉ đổi ảnh hay video đó, không đổi lựa chọn hoặc áp dụng cho toàn bộ nhóm chọn.
3. Ở chế độ xem thông thường, chuyển OFF bằng ⌘⇧M, Esc hoặc đóng bảng. Bộ lọc Nhãn hiển thị Có bất kỳ nhãn đã chọn nào, Có tất cả nhãn đã chọn hoặc Ảnh chưa gắn nhãn. Trong So sánh ảnh, đặt bộ lọc riêng dưới tên mỗi khung.

### Giữ nhịp duyệt ổn định

Gắn nhãn không tự chuyển mục. Khi ON, danh sách giữ nguyên và ←/→ trong Trình xem chuyển cả trang; OFF cập nhật kết quả. So sánh cũng hoãn cập nhật tự động, trừ khi đổi bộ lọc trực tiếp. Trong Trình xem, chỉ gắn nhãn sau khi ảnh hoặc bản xem trước video yêu cầu đã hiển thị.

### Ý nghĩa của các phím

Tên ban đầu: 1–4 Một sao, Hai sao, Ba sao, Bốn sao; Q Tải lên, W Chỉnh sửa, E Xóa, R Chờ xử lý; A Phong cảnh, S Người, D Đồ vật, F Động vật. Đây chỉ là nhãn có thể sửa; phím không tải lên, chỉnh sửa, xóa hay di chuyển tệp. Tên đã lưu được giữ nguyên.

### Lưu trên máy

Nhãn đã gắn, tên và màu nhãn được lưu trong cơ sở dữ liệu cục bộ của ứng dụng và có lại sau khi mở ứng dụng lần nữa. Chúng tách biệt với EXIF và không đồng bộ qua XMP hay thư viện ảnh đám mây.

### Điều cần biết

- Khi OFF, 1 và F trở lại Kích thước thực và chế độ tập trung. Video toàn màn hình có nút bật/tắt, menu và phím nhãn cho chính video đó; ←/→ vẫn đổi vị trí phát và Esc đóng toàn màn hình trước.

[Về đầu trang](#top)

---

<a name="tag-editor"></a>

## 6. Đặt tên, màu nhãn và hiểu giới hạn theo dõi ảnh

Đặt tên phù hợp công việc cho mười hai phím nhãn. Cùng một bộ tên áp dụng cho mọi thư mục; đổi tên không làm mất nhãn đã gắn.

![Trình sửa dùng chung cho tên và màu nhãn.](figures/tag-editor.png)

**Màn hình 06.** Trình sửa dùng chung cho tên và màu nhãn.

1. **Tên theo phím** — Mỗi phím cố định có tên chỉnh sửa được; mọi thư mục dùng chung các tên này.
2. **Màu sắc** — Chọn dấu hiệu dễ nhận biết từ bảng mười màu.
3. **Xem trước và lưu** — Kiểm tra các phím được gán, rồi lưu để giữ cho lần sử dụng tiếp theo.

### Các bước thực hiện

1. Mở Cài đặt → Nhãn ảnh, hoặc chọn Nhãn ảnh → Sửa tên và màu nhãn…. Bạn có thể sửa trước khi mở ảnh.
2. Nhập tên cho từng phím và chọn một trong mười màu. Phần Nhãn theo phím cập nhật bản xem trước khi bạn nhập.
3. Bấm Lưu để áp dụng tên và màu ở mọi nơi. Hủy thay đổi trong Cài đặt khôi phục các giá trị đã lưu gần nhất; Hủy trong cửa sổ chỉnh sửa riêng đóng cửa sổ mà không lưu.

### Dấu hiệu màu nhất quán

Màu xuất hiện trong bảng nhãn, menu, bộ lọc và dấu trên ảnh thu nhỏ. Dấu chọn cùng nền được chọn cũng thể hiện trạng thái nhãn, nên màu không phải dấu hiệu duy nhất. Đổi tên hoặc màu không xóa nhãn đã gắn cho ảnh.

### Đổi tên và di chuyển

Đổi tên trong ứng dụng giữ liên kết nhãn. Ứng dụng lưu dấu truy cập macOS và thông tin nhận dạng của ảnh đã gắn nhãn để theo dõi việc đổi tên trong Finder hoặc di chuyển trong cùng phân vùng khi có thể. Việc kiểm tra diễn ra lúc khởi động, kiểm tra lại báo cáo hoặc mở danh sách ảnh ở nơi mới, không phải giám sát hệ thống tệp liên tục. Ảnh trong ZIP được nhận dạng bằng tệp ZIP và đường dẫn bên trong. Sau khi đổi tên hoặc di chuyển bằng Finder hay ứng dụng khác, hãy mở lại thư mục để làm mới danh sách ảnh đang hiển thị. Chỉ kiểm tra lại báo cáo sẽ không làm mới danh sách đang mở.

### Giới hạn theo dõi và báo cáo đã lưu

Mở Nhãn ảnh → Báo cáo tệp phân loại… để xem ghi nhận tệp không tìm thấy, tên hoặc vị trí đã đổi và tệp được tìm thấy trở lại. Lịch sử được giữ sau khi khởi động lại. Ổ đĩa ngắt kết nối hoặc thiếu quyền cũng có thể khiến tệp không truy cập được, nên báo cáo không khẳng định tệp đã bị xóa. Bản sao và tệp thay thế ở cùng đường dẫn không kế thừa nhãn. Di chuyển sang phân vùng khác, dấu truy cập hết hiệu lực hoặc quyền thay đổi có thể làm mất khả năng theo dõi. Với nhãn cũ chỉ dựa trên đường dẫn, mở ảnh một lần ở nơi gốc trước khi di chuyển.

### Điều cần biết

- Nhãn, tên, màu và báo cáo được lưu trong cơ sở dữ liệu SQLite trên Mac này: ~/Library/Application Support/org.openimageviewer.ImageViewer/PhotoMarks.sqlite. Ứng dụng không ghi vào ảnh gốc, không tìm toàn bộ ổ đĩa hoặc phân tích nội dung để tìm tệp thất lạc. Hãy sao lưu ảnh gốc và dữ liệu cục bộ của ứng dụng.

[Về đầu trang](#top)

---

<a name="map"></a>

## 7. Tìm ảnh theo vị trí

Xem bản đồ đặt các ảnh có siêu dữ liệu GPS lên bản đồ. Kết hợp tối đa ba vùng để cùng duyệt ảnh từ nhiều địa điểm.

![Xem bản đồ với các vùng có thể chọn và phần tóm tắt ảnh phù hợp.](figures/map.png)

**Màn hình 07.** Xem bản đồ với các vùng có thể chọn và phần tóm tắt ảnh phù hợp.

1. **Công cụ vùng** — Thêm vùng tròn, chữ nhật, đường bao tự do hoặc phạm vi bản đồ hiện tại.
2. **Tay nắm vùng** — Di chuyển và đổi kích thước vùng đang chọn; kết hợp tối đa ba vùng.
3. **Duyệt kết quả** — Mở kết quả trong Trình xem hoặc Xem tất cả, hoặc dùng Ảnh trong vùng để xử lý hàng loạt và chia sẻ.

### Các bước thực hiện

1. Mở bộ ảnh và chọn Xem bản đồ. Các ảnh gần nhau được gom thành ảnh thu nhỏ xếp chồng kèm số lượng. Bấm vị trí để xem trước ảnh rồi dùng Xem ảnh để mở một ảnh.
2. Chọn Bán kính hoặc Hình chữ nhật để thêm vùng tại tâm bản đồ hiện tại. Kéo tay nắm có số để di chuyển, kéo tay nắm nhỏ để đổi kích thước. Bán kính cũng có thể nhập bằng kilômét.
3. Chọn Vùng vẽ tự do rồi vẽ đường bao, hoặc thêm Vùng bản đồ hiện tại. Thêm tối đa ba vùng, sau đó dùng Mở trình xem hoặc Mở tổng quan để duyệt ảnh phù hợp; lựa chọn sau mở Xem tất cả. Dùng Ảnh trong vùng để trực tiếp đổi tên, chuyển đổi, thu nhỏ hoặc chia sẻ kết quả trong vùng. Menu ghim áp dụng cho một ảnh hoặc tất cả ảnh tại vị trí đó.

### Kết hợp và sửa vùng

Ảnh trong bất kỳ vùng đã chọn nào đều được đưa vào, nhưng chỉ xuất hiện một lần dù các vùng chồng nhau. Chọn Vùng 1, 2 hoặc 3 để sửa; dùng × tương ứng để xóa hoặc xóa tất cả. Esc hủy nét vẽ tự do, hoặc hoàn tác việc di chuyển hay đổi kích thước đang thực hiện.

### Giữ bộ ảnh đã chọn

Thanh màu xanh “Chỉ hiển thị ảnh đã chọn trên bản đồ” phía trên Trình xem và Xem tất cả cho biết số vùng và số ảnh hiển thị. Thanh vẫn hiện trong chế độ tập trung và khi không có kết quả. Mở lựa chọn trong Trình xem hoặc Xem tất cả vẫn giữ giới hạn bản đồ. Các bộ lọc tên tệp, định dạng và nhãn cũng áp dụng. Xóa vùng bản đồ trở về danh sách lọc không giới hạn vị trí, gồm cả ảnh không có GPS. Mở một ảnh trên bản đồ nằm ngoài vùng chọn chỉ bỏ giới hạn địa lý.

### Tải và lưu trạng thái

Sau khi đổi chế độ xem, Quay lại bản đồ hoặc Xem bản đồ khôi phục vị trí và mức thu phóng cuối. Khi khởi động lại ứng dụng, bản đồ căn theo vùng chọn được khôi phục thay vì vị trí chính xác. Mở thư mục mới đặt lại vùng chọn và vị trí bản đồ. Nền bản đồ cần internet. Ảnh không có GPS không xuất hiện; đọc vị trí của bộ ảnh lớn có thể mất thời gian.

### Điều cần biết

- Nếu không có ảnh phù hợp, hãy mở rộng hoặc di chuyển vùng và kiểm tra các bộ lọc khác. Nút mở lựa chọn chưa dùng được khi đang tải hoặc không có kết quả.

[Về đầu trang](#top)

---

<a name="information"></a>

## 8. Xem thông tin ảnh và siêu dữ liệu

Nút i hình tròn vẫn là Thông tin ảnh, dùng để xem chi tiết ảnh hiện tại. Câu chuyện của ứng dụng nằm trong Trợ giúp → Giới thiệu.

### Các bước thực hiện

1. Chọn ảnh rồi bấm nút i hình tròn, hoặc dùng Điều hướng → Bảng thông tin ảnh.
2. Xem kích thước tệp, kích thước ảnh, thông tin màu và dữ liệu máy ảnh/EXIF sẵn có. Nếu có GPS, bảng hiển thị bản đồ Apple; Google Maps mở cùng tọa độ bên ngoài ứng dụng.
3. Để sửa các thông tin tệp hoặc trường nhúng được hỗ trợ, mở Sửa thông tin ảnh, đổi giá trị và kiểm tra trước khi Lưu.

### Lưu siêu dữ liệu làm thay đổi tệp

Khác với điều chỉnh hình ảnh, chỉnh sửa siêu dữ liệu ghi trở lại tệp nguồn. Các trường có thể sửa gồm tên tệp, ngày sửa đổi, mô tả, quyền sử dụng, DPI, thông tin máy ảnh và GPS nếu định dạng hỗ trợ. Trình sửa chuẩn bị tệp tạm trước khi thay thế tệp ở đường dẫn gốc. Trường nhúng không được hỗ trợ sẽ bị vô hiệu hóa; ảnh trong ZIP chỉ để đọc.

### Xóa hoặc sửa giá trị

Để trống một trường văn bản có thể sửa sẽ xóa thẻ đó khi lưu. Tắt GPS xóa các thẻ vị trí EXIF/XMP tiêu chuẩn. Tọa độ cần cả vĩ độ và kinh độ. Đổi phần mở rộng không chuyển đổi ảnh; hãy dùng Xuất hoặc Đổi định dạng, kích thước và nén hàng loạt.

### Đọc biểu đồ tần suất đúng cách

Biểu đồ RGB và độ chói mô tả bản xem trước SDR, có trọng số theo độ trong suốt và cập nhật theo chỉnh sửa. Tỷ lệ đen và trắng đếm pixel xem trước có mọi kênh RGB đều bằng 0 hoặc 255. Đây không phải biểu đồ cảm biến RAW hay phép đo dải sáng HDR của ảnh gốc.

### Điều cần biết

- Giữ một bản sao trước khi sửa siêu dữ liệu mà sau này bạn có thể muốn hoàn tác. Biểu tượng i dành cho ảnh; Trợ giúp → Giới thiệu mở phần giới thiệu ứng dụng và thông tin giấy phép.

[Về đầu trang](#top)

---

<a name="editing"></a>

## 9. Chỉnh sửa ảnh và xuất bản sao

Chỉnh sửa ảnh xem trước thay đổi mà không ghi đè ảnh gốc. Hãy xuất kết quả trước khi thoát: các điều chỉnh chỉ được giữ trong lần chạy ứng dụng hiện tại.

![Bảng chỉnh sửa bên cạnh bản xem trước của ảnh hiện tại.](figures/editing.png)

**Màn hình 08.** Bảng chỉnh sửa bên cạnh bản xem trước của ảnh hiện tại.

1. **Độ nổi bật và phong cách phim** — Mở Độ nổi bật để chỉnh ảnh hoặc chọn phong cách phim và cường độ.
2. **Xem trước ảnh** — Kiểm tra kết quả hiện tại; dùng Kích thước thực khi điều chỉnh chi tiết.
3. **Bản sao và dấu chìm** — Chọn định dạng, chất lượng rồi xuất bản sao. Thêm dấu chìm… chỉ áp dụng cho ảnh hiện tại.

### Các bước thực hiện

1. Chọn ảnh và bấm nút Chỉnh sửa ảnh có hình thanh trượt. Mở từ Xem tất cả sẽ chuyển sang Trình xem của ảnh đó.
2. Kéo một hình chữ nhật trên ảnh để cắt. Kéo bên trong để di chuyển, kéo góc để đổi kích thước hoặc nhập tỷ lệ và kích thước. Áp dụng vùng cắt; hủy cửa sổ cắt giữ các chỉnh sửa trước đó. Xoay theo bước 90° hoặc dùng Lật ngang / Lật dọc.
3. Điều chỉnh ánh sáng, màu sắc và chi tiết. Chọn định dạng đầu ra và chất lượng khả dụng trong bảng chỉnh sửa, rồi bấm Xuất… hoặc nhấn ⌘E để lưu tệp mới.

### Các điều chỉnh

Dùng độ phơi sáng, độ sáng, độ tương phản, vùng sáng, vùng tối, điểm đen và vùng trắng để chỉnh sáng tối; sắc độ, nhiệt độ màu, độ rực màu và độ bão hòa để chỉnh màu. Đường cong tông màu cho phép chỉnh RGB hoặc từng kênh với năm điểm. Bộ trộn tám màu điều chỉnh sắc độ, độ bão hòa và độ sáng từng màu. Kết cấu, độ rõ, khử sương và phong cách phim cung cấp thêm lựa chọn.

### Đặt lại và kiểm tra

Đặt lại bỏ mọi điều chỉnh hình ảnh của ảnh hiện tại. Bỏ cắt ảnh giữ các chỉnh sửa khác. Bấm lại cùng nút lật sẽ hoàn tác lần lật đó. Kiểm tra độ sắc nét và giảm nhiễu ở Kích thước thực và trong tệp đã xuất.

### Lưu trước khi thoát

Mỗi ảnh giữ điều chỉnh riêng trong lúc ứng dụng còn mở. Lần khởi chạy tiếp theo không khôi phục chúng. Tên xuất mặc định kết thúc bằng -edited và ứng dụng chặn lưu đè nguồn. Các định dạng khả dụng phụ thuộc bộ mã hóa do macOS cung cấp.

### Điều cần biết

- So sánh ảnh hiển thị bản gốc, không dùng các điều chỉnh này. Phóng to bằng AI cũng lấy ảnh nguồn không kèm chỉnh sửa của trình xem; hãy xuất bản đã sửa trước nếu muốn phóng to kết quả đó.

[Về đầu trang](#top)

---

<a name="batch"></a>

## 10. Đổi tên, chuyển đổi, thu nhỏ và chia sẻ nhiều ảnh

Xử lý hàng loạt ảnh đã chọn từ Trình xem, Xem tất cả, danh sách lọc theo nhãn hoặc bản đồ. Đổi tên sửa tên tệp nguồn; đổi định dạng, kích thước và nén tạo tệp mới. Bạn cũng có thể dùng chức năng chia sẻ gốc của macOS.

![Cửa sổ chuyển đổi hàng loạt với định dạng, thu nhỏ đúng tỷ lệ và nơi lưu.](figures/batch.png)

**Màn hình 09.** Cửa sổ chuyển đổi hàng loạt với định dạng, thu nhỏ đúng tỷ lệ và nơi lưu.

1. **Định dạng và kích thước** — Chọn định dạng và kích thước đúng tỷ lệ. Định dạng mất dữ liệu có chỉnh chất lượng; cũng có thiết lập giảm dung lượng.
2. **Dấu chìm và thư mục** — Mở cài đặt dấu chìm hoặc chọn thư mục lưu bản sao.
3. **Xem trước tệp lưu** — So sánh tên hiện tại và tên đầu ra trước khi chuyển đổi. Giữ nguyên bản gốc.

### Các bước thực hiện

1. Chọn ảnh bằng cách bấm, ⌘-bấm, ⇧-bấm hoặc ⌘A trên ảnh thu nhỏ; trong Xem tất cả còn có thể kéo vùng chọn. Có thể lọc theo nhãn trước. Trên bản đồ, dùng Ảnh trong vùng; menu của ghim có Ảnh này và Tất cả ảnh tại vị trí này.
2. Trong Đổi tên hàng loạt…, giữ hoặc thay tên, tìm và thay văn bản, thêm tiền tố, hậu tố và số thứ tự. Với Dùng tên phân loại, chọn rõ Phân loại dùng để đặt tên. Chỉ các tệp đã chọn thuộc phân loại đó được đổi tên. Kiểm tra danh sách tên cũ và mới trước khi áp dụng.
3. Trong Đổi định dạng, kích thước và nén hàng loạt…, chọn định dạng, chất lượng, kích thước ảnh và thư mục đích; kiểm tra tên đầu ra. Chia sẻ tệp… gửi các tệp gốc đã chọn tới bảng chia sẻ của macOS; Chia sẻ tệp đã hoàn tất… dùng các tệp xuất thành công. Dịch vụ chia sẻ khả dụng phụ thuộc macOS.

### Tên phân loại và số thứ tự

Dùng tên phân loại tạo tên như Tải lên01, Tải lên02 theo thứ tự danh sách. Tối đa 99 tệp dùng hai chữ số; từ 100 tệp dùng 001, 002; từ 1000 tệp tiếp tục tăng số chữ số. Ảnh có nhiều nhãn chỉ được xử lý một lần theo phân loại đã chọn; các tệp còn lại không đổi. Đánh số thông thường mặc định hai chữ số, cho phép đặt số đầu, bước tăng, số chữ số và dấu phân cách. Tên phân loại trống, tên không hợp lệ hoặc trùng đích sẽ ngăn áp dụng. Không đổi tên trực tiếp tệp trong ZIP.

### Định dạng, kích thước và dung lượng

Đổi phần mở rộng chỉ chỉnh chữ hoa/thường hoặc cách viết cùng định dạng như .jpg/.jpeg. Để đổi HEIC sang JPEG, dùng Đổi định dạng, kích thước và nén hàng loạt…. Cạnh dài nhất hoặc Tỷ lệ phần trăm thu nhỏ đúng tỷ lệ sau các điều chỉnh và cắt hiện tại; ảnh nhỏ không bị phóng to. Thiết lập giảm dung lượng dùng JPEG, cạnh dài 1920 pixel, chất lượng 75%. Dung lượng thực tế tùy ảnh và có thể lớn hơn tệp gốc.

### Ảnh gốc, kết quả và chia sẻ

Chuyển đổi áp dụng điều chỉnh hiện tại vào bản sao và giữ tệp gốc. Tên đầu ra đã có được thêm số. Ảnh động và nhiều trang chỉ lưu khung đầu. Dừng thao tác vẫn giữ tệp đã xong; kết quả báo số đã lưu, thất bại và chưa xử lý. Chia sẻ tệp gốc không bao gồm điều chỉnh chưa lưu. Muốn chia sẻ ảnh đã chỉnh hoặc thu nhỏ, hãy hoàn thành chuyển đổi rồi chia sẻ các tệp đã hoàn tất. Chuyển đổi ảnh hàng loạt không xử lý video: dùng Khung hình và đoạn phim… để trích xuất PNG hoặc lưu đoạn phim. Để giữ nhiều khung của ảnh động trong GIF hoặc APNG, cũng dùng Khung hình và đoạn phim… (chương 13).

### Điều cần biết

- Kiểm tra số tệp và bản xem trước trước khi đổi tên. Đổi tên trong ứng dụng giữ liên kết nhãn; bản sao xuất ra là ảnh riêng, không tự kế thừa nhãn. Chọn đích và thao tác gửi trong bảng chia sẻ của macOS.

[Về đầu trang](#top)

---

<a name="watermark"></a>

## 11. Thêm dấu chìm bằng chữ, EXIF và logo

Đặt chữ, chữ ký, thông tin chụp và logo lên bản sao của một hoặc nhiều ảnh đã chọn. Giữ nguyên tệp gốc và nhãn của chúng.

![Kết hợp chữ, EXIF và logo, kéo dấu chìm trong bản xem trước rồi chọn mở rộng khung ảnh.](figures/watermark.png)

**Màn hình 10.** Kết hợp chữ, EXIF và logo, kéo dấu chìm trong bản xem trước rồi chọn mở rộng khung ảnh.

1. **Chữ, phông và EXIF** — Chọn chữ, phông và EXIF của từng ảnh. Thêm mục vẫn giữ cỡ chữ.
2. **Logo và bố cục** — Chọn logo, chỉnh kích thước, lề và độ đục bằng thanh trượt hoặc số.
3. **Xem trước ảnh đầu** — Kéo dấu chìm; đường viền hướng dẫn không được lưu. Ra ngoài ảnh sẽ hỏi mở rộng khung.

### Các bước thực hiện

1. Chọn ảnh rồi mở Thêm dấu chìm… từ menu Hình ảnh, thao tác lựa chọn hoặc menu bấm phải. Trên bản đồ, áp dụng cho vùng hoặc ghim được nêu. Thêm dấu chìm… trong bảng chỉnh sửa chỉ dùng ảnh hiện tại.
2. Nhập chữ hoặc chữ ký. Bấm tên phông để mở bảng phông chữ macOS và chọn phông đã cài. Chọn mục EXIF muốn vẽ; Chọn ảnh… thêm logo hoặc ảnh chữ ký, chẳng hạn PNG trong suốt.
3. Chọn một trong chín vị trí hoặc kéo dấu chìm trong bản xem trước. Chỉnh kích thước, lề, độ đục bằng thanh trượt hoặc số như 25,5%, rồi chọn chữ trắng/đen và bóng/nền. Đặt ra ngoài ảnh sẽ hỏi mở rộng khung. Bấm Áp dụng, chọn định dạng, chất lượng, thu nhỏ và thư mục rồi Bắt đầu chuyển đổi.

### Thông tin chụp và cỡ chữ ổn định

EXIF vẽ giá trị của từng ảnh gốc: thời điểm chụp, hãng, mẫu máy, ống kính, màn trập, khẩu độ, ISO, tiêu cự và tên tệp. Bỏ qua dữ liệu thiếu hoặc không đọc được. Thêm mục EXIF chỉ thêm hàng hoặc ngắt dòng, không thu nhỏ chữ. Muốn sửa siêu dữ liệu trong tệp, dùng trình chỉnh sửa trong Thông tin ảnh.

### Kéo vị trí và mở rộng khung ảnh

Cỡ chữ và logo theo chiều rộng ảnh trước khi mở rộng, logo giữ tỷ lệ. Lề theo cạnh ngắn chỉ dùng ở vị trí có sẵn; kéo sẽ đặt tâm tùy chỉnh. Vị trí, kích thước tương đối và đồng ý mở rộng áp dụng cho cả lựa chọn, chỉ thêm cạnh cần thiết mà không đổi kích thước ảnh. Phần thêm trong suốt với alpha, trắng với JPEG. Giữ trong ảnh chỉ đưa vị trí ngoài ảnh vào trong. Nội dung quá lớn cho chọn Mở rộng khung ảnh, Thu nhỏ dấu chìm cho vừa hoặc Hủy. Hủy giữ cài đặt hiện tại. Chỉ khi không mở rộng khung mà nội dung không vừa ảnh thì mới chặn lưu đến khi xử lý xong. Trở về khung gốc cũng kiểm tra kích thước.

### Bản sao, xem trước và thiết kế ghi nhớ

Dấu chìm áp dụng sau chỉnh sửa, cắt, xoay và thu nhỏ đầu ra. Bản xem trước ảnh đầu thu nhỏ có thể lệch nhẹ vị trí cuối do làm tròn điểm ảnh; kích thước và EXIF khác nhau theo ảnh. Giữ ảnh gốc và nhãn; chia sẻ bản sao hoàn tất qua macOS. Nhớ thiết kế và vị trí tùy chỉnh nhưng mỗi chuyển đổi mới phải bật lại dấu chìm. Đồng ý mở rộng được đặt lại cho mỗi đợt mới; kéo ra ngoài lần nữa sẽ hỏi lại. Giữ logo ở cùng đường dẫn; báo lỗi nếu không đọc được. Không dùng cho video; ảnh động và nhiều trang lưu khung đầu thành ảnh tĩnh.

### Điều cần biết

- Chữ tối đa 2.000 ký tự, 20 dòng; logo dùng khung đầu của ảnh ImageIO đọc được. Kích thước 2–90%, lề 0–20%, độ đục 0–100%. Số vượt phạm vi bị giới hạn; nhập sai giữ giá trị hợp lệ trước đó. Đầu ra mở rộng tối đa 64 MP, mỗi cạnh 32.768 px; vượt giới hạn thì kéo vào trong hoặc thu nhỏ. Dấu chìm không hiện trên ảnh gốc trong Trình xem.

[Về đầu trang](#top)

---

<a name="video"></a>

## 12. Phát video, trích xuất khung hình và lưu đoạn phim

Ảnh và video mặc định hiển thị cùng nhau. Xem tất cả dùng ảnh xem trước tĩnh; một video riêng mở ở trạng thái tạm dừng. Khung hình và đoạn phim… cho phép trích xuất PNG hoặc lưu đoạn phim mà giữ nguyên tệp gốc.

![Cửa sổ Khung hình và đoạn phim cho video, với trình phát và thiết lập xuất.](figures/video.png)

**Màn hình 11.** Cửa sổ Khung hình và đoạn phim cho video, với trình phát và thiết lập xuất.

1. **Trình phát video** — Phát hoặc tạm dừng video để kiểm tra hình ảnh và âm thanh.
2. **Khung hình và vị trí** — Duyệt từng khung hình khi được hỗ trợ hoặc tìm theo thời điểm, rồi trích xuất khung hiện tại thành PNG.
3. **Khoảng và chất lượng** — Đặt điểm đầu được bao gồm, điểm cuối không được bao gồm, định dạng và thiết lập trước khi lưu bản sao.

### Các bước thực hiện

1. Khi xem nhiều mục, di chuột lên video để phát tắt tiếng; chọn Bật âm thanh để nghe. Rời con trỏ khỏi ô sẽ dừng phát và tắt tiếng lại. Nhấp đúp video trong Xem tất cả hoặc Trình xem để mở riêng toàn màn hình, tự phát từ thời điểm hiện tại với cùng trạng thái âm thanh. Dùng điều khiển để phát, tìm và chỉnh âm thanh; Esc hoặc Đóng toàn màn hình trở về bố cục ban đầu. Hiển thị video trong danh sách, menu hoặc cài đặt cho phép ẩn video mà không ảnh hưởng đến GIF.
2. Trong Khung hình và đoạn phim…, dùng vị trí phát và Khung hình trước / Khung hình tiếp theo nếu nội dung hỗ trợ bước từng khung. Thao tác này đi theo khung hình thực; ứng dụng không khẳng định số khung hình chính xác bằng cách tính từ tốc độ khung hình danh nghĩa của video có tốc độ thay đổi.
3. Dùng Trích xuất khung hình hiện tại thành PNG… để lưu hình đang hiển thị. Để lưu đoạn phim, đặt Bắt đầu (giây) và Kết thúc (giây), có thể dùng Đặt điểm bắt đầu tại đây / Đặt điểm kết thúc tại đây; chọn MP4 hoặc MOV, chất lượng rồi Lưu bản sao đoạn phim….

### Định dạng khả dụng trên máy Mac này

Khả năng hỗ trợ tùy thuộc vào định dạng vùng chứa và codec mà phiên bản macOS đang cài thực sự giải mã được: MP4, MOV và các định dạng gốc khác có thể dùng mà không cần cài codec bên ngoài. Chỉ phần mở rộng không bảo đảm phát được. Không hỗ trợ WebM, MKV hoặc video bên trong ZIP. Không thể lưu khung hình hay đoạn phim từ video được bảo vệ bằng DRM. Bản đồ không sử dụng dữ liệu GPS của video.

### Khoảng và chất lượng bản sao

Bao gồm điểm bắt đầu và không bao gồm điểm kết thúc; ranh giới được lưu sẽ căn theo các mẫu của nội dung đa phương tiện. Đoạn phim được mã hóa lại thành H.264/AAC trong vùng chứa MP4 hoặc MOV, còn tệp gốc được giữ nguyên. Cài đặt giảm dung lượng chọn MP4 và mức tối đa 720p. Các mức chất lượng và độ phân giải không phóng lớn video nhỏ, cũng không bảo đảm tệp sẽ nhỏ hơn: đầu ra có thể lớn hơn bản gốc. Trích xuất PNG giữ độ phân giải của khung hình gốc; chất lượng đã chọn chỉ áp dụng cho bản sao đoạn phim.

### Các tính năng chỉ dành cho ảnh

Điều chỉnh ảnh, phóng to bằng AI, đặt hình nền và chuyển đổi ảnh hàng loạt không áp dụng cho video. So sánh ảnh vẫn chỉ dành cho ảnh. Không thể khởi động album ảnh nếu danh sách đang hiển thị có video; tắt Hiển thị video để chạy trình chiếu chỉ gồm ảnh. Video vẫn có thể được gắn nhãn, đổi tên và chia sẻ tệp gốc đã chọn. Bản sao mới không tự kế thừa nhãn của tệp gốc.

### Điều cần biết

- Hãy chọn tên mới: tệp gốc và tệp đã có sẽ không bị ghi đè. Hủy sẽ xóa bản sao chưa hoàn tất. Kết quả đã lưu thành công có thể được chia sẻ bằng chức năng chia sẻ của macOS.

[Về đầu trang](#top)

---

<a name="animation"></a>

## 13. Duyệt và lưu các khung hình của ảnh động

Khung hình và đoạn phim… cho phép duyệt GIF, APNG và WebP mà máy Mac này giải mã được, trích xuất PNG và lưu một khoảng thành GIF hoặc APNG.

![Cửa sổ Khung hình và đoạn phim cho ảnh động, với bản xem trước, khung hình và kích thước đầu ra.](figures/animation.png)

**Màn hình 12.** Cửa sổ Khung hình và đoạn phim cho ảnh động, với bản xem trước, khung hình và kích thước đầu ra.

1. **Bản xem trước ảnh động** — Kiểm tra khung đang hiển thị và chuyển động trước khi lưu.
2. **Điều khiển khung hình** — Tiến hoặc lùi một khung và trích xuất khung hiện tại thành PNG.
3. **Khoảng và kích thước** — Chọn khoảng bao gồm cả hai đầu, GIF hoặc APNG, kích thước và các khung cần giữ.

### Các bước thực hiện

1. Mở ảnh động được hỗ trợ rồi chọn Khung hình và đoạn phim…. GIF vẫn hiển thị khi Hiển thị video bị tắt. Kiểm tra bản xem trước và dùng Phát / Tạm dừng hoặc các nút khung hình trước và tiếp theo.
2. Dùng Trích xuất khung hình hiện tại thành PNG… để lấy ảnh tĩnh. Để lưu một khoảng ảnh động, nhập Khung hình đầu và Khung hình cuối: số thứ tự bắt đầu từ 1 và bao gồm cả hai khung giới hạn.
3. Chọn GIF hoặc APNG trong các định dạng khả dụng trên máy Mac này. Đặt kích thước và Giữ khung hình, rồi dùng Lưu bản sao đoạn phim… để tạo tệp mới.

### Khung hình giữ lại và thời lượng

Bạn có thể giữ tất cả khung hình hoặc 1 trong 2, 3 hay 4 khung của khoảng đã chọn. Thời lượng của các khung bị bỏ được cộng vào một khung giữ lại để duy trì tổng thời lượng của khoảng, thay vì làm ảnh động chạy nhanh hơn.

### Kích thước và giảm dung lượng

Giữ Kích thước gốc, đặt Cạnh dài nhất theo pixel hoặc dùng Tỷ lệ từ 1 đến 100 %. Tỷ lệ khung hình được giữ nguyên và ảnh nhỏ không bị phóng lớn. Cài đặt giảm dung lượng đặt 50 % và giữ 1 trong 2 khung hình. Dung lượng tùy thuộc nội dung và định dạng; không bảo đảm tệp sẽ nhỏ hơn. Trích xuất PNG giữ độ phân giải của khung hình gốc; thiết lập kích thước và giữ khung hình chỉ áp dụng cho bản sao ảnh động.

### Định dạng và hình ảnh

Khả năng đọc GIF, APNG, WebP và các định dạng đầu ra được cung cấp tùy thuộc khả năng giải mã và mã hóa của máy Mac này. Bản sao ảnh động chỉ được lưu thành GIF hoặc APNG. GIF giới hạn màu sắc và độ trong suốt nên hình ảnh có thể thay đổi. Các điều chỉnh chỉnh sửa ảnh hiện tại không được áp dụng cho khung PNG trích xuất hoặc bản sao ảnh động.

### Điều cần biết

- Giữ nguyên tệp gốc và từ chối tên tệp đã tồn tại. Hủy sẽ xóa đầu ra chưa hoàn tất. Sau khi lưu thành công, có thể chia sẻ bản sao đã hoàn tất qua chức năng chia sẻ của macOS. Bản sao mới không tự kế thừa nhãn của tệp gốc.

[Về đầu trang](#top)

---

<a name="ai-upscaling"></a>

## 14. Phóng to và so sánh kết quả AI

Phóng to bằng AI tạo ảnh mới có chiều rộng và chiều cao đều gấp đôi. Xem kỹ chi tiết và so sánh cùng một vùng với ảnh gốc trước khi lưu bản sao PNG.

![Bản xem trước cho phép điều chỉnh thu phóng và di chuyển đường phân chia để so sánh cùng một vùng của ảnh gốc và kết quả AI.](figures/ai-upscaling.png)

**Màn hình 13.** Bản xem trước cho phép điều chỉnh thu phóng và di chuyển đường phân chia để so sánh cùng một vùng của ảnh gốc và kết quả AI.

1. **Chế độ xem và thu phóng** — Chọn Kết quả phóng to bằng AI hoặc So sánh với ảnh gốc. Kiểm tra chi tiết bằng +/−, phần trăm, Vừa cửa sổ và 100% · Điểm ảnh thực tế.
2. **Đường phân chia ảnh gốc và AI** — Di chuyển đường phân chia giữa ảnh gốc bên trái và kết quả AI bên phải. Kéo ảnh hoặc cuộn sẽ di chuyển cả hai bên cùng nhau.
3. **Lưu bản sao PNG** — Lưu toàn bộ kết quả 2× thành bản sao PNG, không phụ thuộc mức thu phóng bản xem trước.

### Các bước thực hiện

1. Chọn ảnh, mở Phóng to bằng AI… rồi bấm Bắt đầu phóng to bằng AI. Khi xử lý xong, bản xem trước hiển thị Kết quả phóng to bằng AI.
2. Dùng nút +/− hoặc chụm/mở ngón tay trên trackpad để thu phóng. Kéo ảnh hoặc cuộn để di chuyển đến chi tiết cần xem; Vừa cửa sổ hiển thị lại toàn bộ ảnh.
3. Chọn So sánh với ảnh gốc rồi kéo đường phân chia sang trái hoặc phải. Ảnh gốc ở bên trái và kết quả AI ở bên phải, dùng cùng mức thu phóng và vị trí. Sau khi kiểm tra, bấm Lưu bản sao PNG….

### Ý nghĩa của 100% · Điểm ảnh thực tế

Ở mức 100%, một điểm ảnh của kết quả AI được hiển thị bằng một điểm ảnh vật lý trên màn hình. Phép tính có xét tỷ lệ Retina, nên kích thước cửa sổ tính bằng point không nhất thiết bằng kích thước ảnh tính bằng pixel. Phần trăm dựa trên kết quả AI, không phải ảnh gốc. Vừa cửa sổ chọn mức thu phóng để thấy toàn bộ ảnh. Các điều khiển này chỉ thay đổi bản xem trước: không đổi kích thước tệp, kết quả lưu hoặc chạy lại xử lý AI.

### So sánh cùng một chi tiết

Ảnh gốc bên trái được hiển thị 2× bằng nội suy thông thường để có cùng chiều rộng và chiều cao với kết quả AI. Hai bên dùng chung thu phóng và vị trí, nên có thể di chuyển đường phân chia để so sánh cùng đường nét và kết cấu. Kéo đường phân chia để đổi ranh giới so sánh; kéo chỗ khác trên ảnh để di chuyển ảnh. Chi tiết do AI tạo là ước đoán, không đảm bảo khôi phục thông tin thực bị thiếu trong ảnh gốc.

### Đầu ra AI và giới hạn

Mô hình đi kèm chạy cục bộ qua Core ML; ảnh không được tải lên và không cần tải mô hình khi sử dụng. Chiều rộng và chiều cao đều tăng gấp đôi. Đầu ra là PNG sRGB SDR 8-bit, với độ trong suốt được nội suy riêng. Ảnh động dùng khung đầu, không bao gồm chỉnh sửa của trình xem. Đầu ra tối đa 64 triệu pixel và có thể thấp hơn trên Mac ít bộ nhớ. Lưu trước khi đóng; chi tiết do AI tạo là ước đoán.

### Điều cần biết

- Không có AI 4×, đầu ra AI HDR hay phóng to AI hàng loạt. Lưu bản sao PNG trước khi đóng. Tệp gốc không thay đổi.

[Về đầu trang](#top)

---

<a name="quality"></a>

## 15. Hiểu chất lượng hiển thị, HDR và tải ảnh

Phóng to chất lượng cao thay cách nội suy khi hiển thị. Phóng to bằng AI tạo ảnh lớn hơn để lưu. Đầu ra HDR là tùy chọn hiển thị, không phải dấu xác nhận ảnh đang xem là HDR.

### Các bước thực hiện

1. Để hiển thị mượt hơn, bật Phóng to chất lượng cao. So sánh cạnh nhau hoặc trên dưới hiển thị cùng một ảnh với thu phóng và di chuyển liên kết; Esc đóng kiểu so sánh này.
2. Dùng HDR ON / HDR OFF để cho phép hoặc tắt hiển thị dải sáng mở rộng. Trong Cài đặt → Chung → Tải hình ảnh, chọn Ưu tiên, Thoải mái, Bình thường hoặc Chậm theo công việc.

### Định dạng và hiệu năng

Khả năng đọc và ghi phụ thuộc macOS đang chạy. Ứng dụng bổ sung giải mã QOI, các biến thể PCX phổ biến và cách hiển thị dự phòng cho SVG/SVGZ. Không bao gồm BPG và .clip. Thoải mái là chế độ tải mặc định. Mọi chế độ đều giảm tốc khi có áp lực bộ nhớ, nhiệt độ cao, tiết kiệm pin, ứng dụng khác hoặc bộ lưu trữ chậm.

### Điều cần biết

- Khi chuyển nhanh, bản xem trước nhỏ hoặc ảnh trước đó có thể còn hiển thị cho tới khi ảnh cuối sẵn sàng.

[Về đầu trang](#top)

---

<a name="slideshow"></a>

## 16. Phát album ảnh hoặc đặt hình nền

Album ảnh tự chuyển qua danh sách hiện tại trong chế độ tập trung một ảnh. Hình nền dùng bản sao riêng được chuẩn bị cho các màn hình đã chọn.

### Các bước thực hiện

1. Mở danh sách có ít nhất hai ảnh. Chọn Điều hướng → Album ảnh → Phát album ảnh hoặc nhấn ⌃⌥P. Danh sách phải chỉ có ảnh: nếu còn video, hãy tắt Hiển thị video trước khi khởi động album.
2. Dùng các nút phát để tạm dừng. Chọn khoảng 1–300 giây và có lặp lại hay không từ điều khiển thời gian hoặc Cài đặt → Chung → Album ảnh.
3. Để đặt hình nền, trở lại trình xem thông thường rồi chọn Hình ảnh → Đặt ảnh hiện tại làm hình nền… hoặc nhấn ⌃⌥W. Chọn màn hình hiện tại hoặc mọi màn hình kết nối, Lấp đầy màn hình hoặc Hiển thị toàn bộ ảnh, và có áp dụng điều chỉnh hiện tại hay không; sau đó áp dụng.

### Cách phát

Mặc định là năm giây và bật lặp. Bộ đếm bắt đầu sau khi bản xem trước hoặc ảnh đã hiển thị, nên thời gian tải không lấy mất thời gian xem. Chuyển thủ công hoặc đổi khoảng thời gian sẽ khởi động lại bộ đếm. Nếu tắt lặp, phát dừng ở ảnh cuối.

### Tự động tạm dừng

Phát tạm dừng khi thoát chế độ tập trung, chuyển ứng dụng, máy ngủ hoặc bắt đầu thao tác tệp. Chỉ giữ màn hình thức trong khi phát. Mở ứng dụng lại khôi phục thiết lập nhưng không tự khởi động album.

### Bản sao hình nền

Ứng dụng tạo PNG mà không sửa nguồn. Ảnh động dùng khung đầu và HDR được chuẩn bị thành SDR. Bản sao không có EXIF/GPS, được định kích thước cho màn hình với tối đa 8192 pixel và giữ trong thư mục Application Support/Wallpapers của ứng dụng. Các không gian màn hình nền khác theo cách hoạt động của macOS. Bản sao cũ không tự xóa vì không gian khác có thể vẫn dùng. Không thể dùng video làm nguồn để đặt hình nền.

### Điều cần biết

- Nếu không thể phát, kiểm tra danh sách đã lọc hiện tại có ít nhất hai ảnh và không đang bật Phân loại, So sánh ảnh hoặc một thao tác khác. Danh sách phải chỉ có ảnh: nếu còn video, hãy tắt Hiển thị video trước khi khởi động album.

[Về đầu trang](#top)

---

<a name="settings"></a>

## 17. Thiết lập theo cách làm việc của bạn

Cài đặt tập hợp các lựa chọn xem thường ngày, phím tắt riêng, gán nhãn và liên kết tệp mặc định. Nhiều tùy chọn xem được tự khôi phục trong lần chạy sau.

![Cài đặt sắp xếp các tùy chọn chính trong bốn thẻ.](figures/settings.png)

**Màn hình 14.** Cài đặt sắp xếp các tùy chọn chính trong bốn thẻ.

1. **Các thẻ cài đặt** — Chung, Phím tắt, Nhãn ảnh và Liên kết tệp phụ trách các thiết lập khác nhau.
2. **Tùy chọn xem** — Đặt cách hiển thị, ảnh thu nhỏ, tên tệp, điều hướng và tải ảnh.
3. **Giải thích tại chỗ** — Đọc phần chữ dưới điều khiển hoặc di chuột lên đó để biết rõ cách hoạt động.

### Các bước thực hiện

1. Mở 알맹Re → Cài đặt…. Trong Chung, chọn đầu ra HDR/EDR, vị trí ảnh thu nhỏ, cỡ tên tệp, phóng to chất lượng cao, hiển thị cây thư mục và có duyệt vòng hay không.
2. Dùng Nhãn ảnh để lưu tên và màu chung, dùng Phím tắt để chọn phím và các phím bổ trợ. Di chuột lên điều khiển để đọc giải thích.
3. Để Finder mở các định dạng đã chọn bằng ứng dụng này, đặt 알맹Re.app ở vị trí ổn định như Applications, mở Liên kết tệp, chỉ chọn các nhóm định dạng mong muốn rồi áp dụng.

### Ngôn ngữ

Giao diện dùng ngôn ngữ mà macOS chỉ định cho ứng dụng. Đổi tại Cài đặt hệ thống → Cài đặt chung → Ngôn ngữ & Vùng → Ứng dụng, rồi khởi động lại ứng dụng. Hỗ trợ tiếng Hàn, Anh, Nhật, Trung giản thể, Việt, Tây Ban Nha, Pháp, Đức, Nga và Ả Rập. Hướng dẫn cơ bản dùng cùng ngôn ngữ với ứng dụng. Hướng dẫn chi tiết có bảy ngôn ngữ; giao diện tiếng Đức, Nga và Ả Rập sẽ mở bản tiếng Anh.

### Các tùy chọn được ghi nhớ

Kích thước ảnh thu nhỏ, phóng to chất lượng cao, hiển thị tên tệp, tùy chọn tải, mục yêu thích, thiết lập nhãn và phím riêng được giữ lại. Tiếp tục phiên trước trên Trang chủ khôi phục bộ ảnh và vị trí xem nếu tệp vẫn truy cập được. So sánh chất lượng phóng to bắt đầu ở trạng thái tắt sau khi chạy lại. Các chỉnh sửa hình ảnh và kết quả AI cần được xuất riêng. Hiển thị video mặc định bật và ghi nhớ lựa chọn mà không ảnh hưởng đến GIF.

### Liên kết tệp

Chỉ các nhóm định dạng được đánh dấu mới thay đổi. macOS có thể yêu cầu xác nhận. Di chuyển ứng dụng sau đó hoặc giữ các bản cũ có thể khiến Finder mở nhầm phiên bản; hãy áp dụng lại liên kết từ bản bạn muốn dùng.

### Điều cần biết

- Chung cũng liệt kê các định dạng gốc có trên Mac và có Xóa bộ nhớ đệm ảnh. Chọn chế độ tải chậm hơn nếu muốn giảm công việc nền khi dùng ứng dụng khác. Ảnh thu nhỏ RAW ưu tiên bản xem trước nhúng nếu có; ảnh thu nhỏ đủ lớn được dùng lại khi chuyển chế độ xem. Tốc độ hiển thị lần đầu tùy thuộc vào tệp và máy Mac.

[Về đầu trang](#top)

---

<a name="shortcuts"></a>

## 18. Phím tắt và xử lý nhanh vấn đề

Bảng tham khảo tiếp theo liệt kê các phím thao tác mặc định và phím cố định theo ngữ cảnh. ⌘ là Command, ⌥ là Option, ⌃ là Control và ⇧ là Shift.

![Thẻ Phím tắt hiển thị các thao tác có thể gán và thông báo xung đột.](figures/shortcuts.png)

**Màn hình 15.** Thẻ Phím tắt hiển thị các thao tác có thể gán và thông báo xung đột.

1. **Thao tác** — Di chuột lên tên để biết thao tác dùng ở đâu và hoạt động thế nào.
2. **Phím và phím bổ trợ** — Chọn phím, rồi bật/tắt Control, Option, Shift hoặc Command.
3. **Xung đột và mặc định** — Giải quyết tổ hợp trùng nhau hoặc dùng Khôi phục mặc định để bắt đầu lại.

### Các bước thực hiện

1. Mở Cài đặt → Phím tắt để đổi phím và phím bổ trợ của một thao tác. Thay đổi được lưu và tổ hợp hiện tại xuất hiện trong menu.
2. Kiểm tra dấu xung đột khi gán cùng tổ hợp cho nhiều thao tác. Di chuột lên tên thao tác, ô chọn phím, phím bổ trợ hoặc biểu tượng xung đột để xem trợ giúp. Khôi phục mặc định đặt lại các phím thao tác có thể chỉnh.
3. Nếu phím hoạt động ngoài dự kiến, rời ô nhập chữ và kiểm tra chế độ hiện tại. Phân loại dùng mười hai phím cho nhãn; So sánh ảnh dùng Option và mũi tên để điều hướng A/B.

### Không có ảnh hoặc không có kết quả

Bỏ bộ lọc tìm kiếm, định dạng, nhãn và bản đồ. Kiểm tra định dạng đầu vào có đọc được trên macOS này không. Thư mục trống vẫn có thể mở để tiếp tục duyệt thư mục con. Chọn lại ổ đĩa đã ngắt hoặc bộ ảnh đã di chuyển bằng Mở….

### Lệnh bị vô hiệu hóa

Trước hết hoàn thành hoặc hủy thao tác tệp hiện tại. Thoát So sánh ảnh để chỉnh sửa, chuyển đổi hàng loạt hoặc đặt hình nền. Không thể đổi tên trực tiếp hay ghi lại siêu dữ liệu gốc của ảnh trong ZIP. Nút kết quả bản đồ chờ lựa chọn không rỗng và đã tính toán xong.

### Space, Esc và Option kết hợp mũi tên

Space chỉ đổi chế độ tập trung khi không có thao tác riêng dùng Space đơn và bạn không đang nhập chữ. Esc thoát dần chế độ đang hoạt động hoặc hủy cử chỉ chọn. Chuyển trang bằng Option và mũi tên trong Trình xem là cố định, nhưng nhường ưu tiên cho thao tác trình xem thông thường được gán riêng vào cùng tổ hợp.

### Điều cần biết

- Nút i hình tròn và nút thanh trượt mở thông tin và chỉnh sửa ảnh. Dùng các nút hoặc menu Điều hướng; I và E không phải phím tắt mặc định để bật/tắt bảng trong phiên bản này.

[Về đầu trang](#top)

---

<a name="shortcut-reference"></a>

## Bảng phím tắt

| Phím | Thao tác | Điều kiện sử dụng |
| --- | --- | --- |
| ← / → | Ảnh hoặc trang trước / tiếp theo | Có thể gán lại. Với Phân loại ON hay OFF, Trình xem chuyển cả trang và Xem tất cả chuyển từng mục. So sánh theo Chỉ A / Cả hai / Chỉ B. |
| ↑ / ↓ | Chọn hàng phía trên / phía dưới | Trong Xem tất cả và Trình xem nhiều mục, với Phân loại ON hoặc OFF. Trình xem chỉ di chuyển trong trang hiện tại. Dừng ở hàng đầu và cuối; phím tắt tùy chỉnh được ưu tiên khi OFF. |
| ⌥← / ⌥→ | Trang trước / tiếp theo trong trình xem | Phím theo ngữ cảnh cố định khi Trình xem hiển thị nhiều ảnh, kể cả lúc Phân loại; tổ hợp riêng cho trình xem được ưu tiên. |
| = / − | Phóng to / thu nhỏ | Có thể gán lại; áp dụng cho trình xem thông thường hoặc khung so sánh đang hoạt động. |
| 0 / 1 | Vừa cửa sổ / Kích thước thực | Có thể gán lại. Phím 1 đơn là phím nhãn khi Phân loại bật. |
| G | Bật/tắt Xem tất cả | Thao tác xem có thể gán lại. |
| F | Bật/tắt chế độ tập trung | Có thể gán lại. Phím F đơn là phím nhãn khi Phân loại bật. |
| Space (tap) | Bật/tắt chế độ tập trung | Cử chỉ của Trình xem; không hoạt động khi nhập chữ hoặc khi Space được gán thao tác riêng. Giữ Space để di chuyển ảnh không đổi chế độ tập trung. |
| ⌃⌘F | Bật/tắt Toàn màn hình | Phím tắt cố định của menu ứng dụng, tách biệt với chế độ tập trung. |
| \[ / \] | Giảm / tăng số ảnh mỗi màn hình | Có thể gán lại; phạm vi 1–10 ảnh trong Trình xem. |
| ⌘O | Mở ảnh, thư mục hoặc ZIP | Có thể gán lại; trong so sánh, mở ở khung đang hoạt động và không bị khóa. |
| ⌘E | Xuất ảnh hiện tại | Có thể gán lại; dùng trong trình xem thông thường, không có trong So sánh ảnh. |
| ⌃⌥1 | Chọn di chuyển bằng kéo nút trái | Có thể gán lại; chọn cách di chuyển chứ không tự di chuyển ảnh. |
| ⌃⌥2 | Chọn di chuyển bằng Space + kéo nút trái | Lựa chọn cách di chuyển có thể gán lại. |
| ⌃⌥3 | Chọn di chuyển bằng nút phải | Lựa chọn cách di chuyển có thể gán lại. |
| ⌃⌥4 | Chọn di chuyển bằng nút giữa | Lựa chọn cách di chuyển có thể gán lại. |
| ⌃⌥5 | Chọn di chuyển bằng hai ngón trên bàn di chuột | Lựa chọn cách di chuyển có thể gán lại. |
| ⌃⌥A | Bật/tắt Phóng to chất lượng cao | Tùy chọn hiển thị có thể gán lại; không làm thay đổi tệp xuất. |
| ⌃⌥6 / ⌃⌥7 | So sánh chất lượng phóng to cạnh nhau / trên dưới | Có thể gán lại; hiển thị hai cách dựng cùng một ảnh trong Trình xem. |
| ⌃⌥0 | Kết thúc so sánh chất lượng phóng to | Có thể gán lại; Esc cũng đóng so sánh này. |
| ⌃⌥P | Phát / tạm dừng Album ảnh | Có thể gán lại; cần ít nhất hai ảnh và trình xem thông thường đang cho phép thao tác. |
| ⌃⌥W | Đặt ảnh hiện tại làm hình nền | Có thể gán lại; mở tùy chọn hình nền khi ở ngoài So sánh ảnh. |
| ⌃⌥C | Vào / thoát So sánh ảnh | Có thể gán lại; giữ bộ ảnh trước đó trong trình xem thông thường. |
| ⌥← / ⌥→ | Ảnh trước / tiếp theo chỉ ở A | Thao tác so sánh có thể gán lại; A ở trái hoặc trên. Khung bị khóa giữ nguyên. |
| ⇧⌥← / ⇧⌥→ | Ảnh trước / tiếp theo chỉ ở B | Thao tác so sánh có thể gán lại; B ở phải hoặc dưới. Khung bị khóa giữ nguyên. |
| ⌘⇧M | Bật/tắt chế độ Phân loại | Phím tắt cố định của menu ứng dụng. |
| 1 2 3 4 · Q W E R · A S D F | Bật/tắt mười hai nhãn cho ảnh và video | Phím vật lý cố định khi Phân loại ON. Áp dụng cho mục hiện tại, đối tượng Áp dụng nhãn khi so sánh hoặc video đó khi toàn màn hình. Không xóa hay tải tệp lên. |
| ← / → · ↑ / ↓ | Chuyển trang / mục / hàng khi phân loại | ←/→ chuyển cả trang trong Trình xem hoặc từng mục trong Xem tất cả; ↑/↓ chuyển từng hàng trong lưới. Trong Trình xem một mục và So sánh ảnh, ↑/↓ chuyển đến mục trước hoặc tiếp theo. Khi so sánh, việc chuyển ảnh theo thiết lập điều hướng, độc lập với Áp dụng nhãn. |
| ⌘A | Chọn mọi ảnh trong danh sách hiện tại | Phím chọn cố định khi ở ngoài So sánh ảnh; ô nhập chữ vẫn chọn văn bản như bình thường. |
| Esc | Hủy cử chỉ hiện tại hoặc thoát chế độ đang dùng | Cố định. Thoát Phân loại, so sánh, so sánh chất lượng phóng to hoặc tập trung; Trình xem thông thường trở về Xem tất cả. Cũng hủy cử chỉ chọn vùng. |

[Về đầu trang](#top)
