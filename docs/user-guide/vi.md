<!-- almeng-guide-source-sha256: d3bd9c97619002122762a0cc66f6a873fe2f9b8a8ddf7431804e2cf97511f4f4 -->

<a name="top"></a>

# Hướng dẫn sử dụng 알맹Re

[한국어](ko.md) · [English](en.md) · [日本語](ja.md) · [简体中文](zh-Hans.md) · [Français](fr.md) · [Español](es.md) · [Tiếng Việt](vi.md)

[← 알맹Re](../../README.md) · [PDF](pdf/AlmaengRe-User-Guide-vi.pdf)

**Mở, xem, so sánh, phân loại và chỉnh sửa ảnh trên Mac**

Hướng dẫn thực hành cho phiên bản phát triển 0.12 hiện tại. Hãy bắt đầu bằng một thư mục ảnh, rồi tra cứu chương phù hợp với việc bạn muốn làm. Tên menu trong hướng dẫn theo giao diện tiếng Việt của ứng dụng.

Phiên bản 0.12.0 · Tính đến 2026-10-05

> Ảnh chụp màn hình lấy từ ứng dụng thật với giao diện tiếng Hàn và ảnh minh họa được tạo riêng. Các chú thích đánh số và phần giải thích được dịch sang ngôn ngữ của hướng dẫn; nội dung ảnh chụp màn hình giữ nguyên. Không sử dụng bộ sưu tập ảnh cá nhân.

## Mục lục

- [1. Mở ảnh, thư mục và tệp ZIP](#open)
- [2. Duyệt ảnh và xem tập trung](#viewer)
- [3. Tìm và chọn ảnh trong Xem tất cả](#overview)
- [4. So sánh hai bộ ảnh](#compare)
- [5. Phân loại ảnh bằng bàn phím](#tags)
- [6. Đặt tên, màu nhãn và hiểu giới hạn theo dõi ảnh](#tag-editor)
- [7. Tìm ảnh theo vị trí](#map)
- [8. Xem thông tin ảnh và siêu dữ liệu](#information)
- [9. Chỉnh sửa ảnh và xuất bản sao](#editing)
- [10. Đổi tên, chuyển đổi, thu nhỏ và chia sẻ nhiều ảnh](#batch)
- [11. Hiểu phóng to AI, HDR và tải ảnh](#quality)
- [12. Phát album ảnh hoặc đặt hình nền](#slideshow)
- [13. Thiết lập theo cách làm việc của bạn](#settings)
- [14. Phím tắt và xử lý nhanh vấn đề](#shortcuts)
- [Bảng phím tắt](#shortcut-reference)

---

<a name="open"></a>

## 1. Mở ảnh, thư mục và tệp ZIP

Dùng Mở… cho mọi loại đầu vào. Một ảnh, một thư mục hay một tệp ZIP đều dùng chung cách duyệt ảnh.

### Các bước thực hiện

1. Chạy 알맹Re trên macOS 14 trở lên. Chọn Mở… trên màn hình bắt đầu, thanh công cụ hoặc menu Tệp, hay nhấn ⌘O.
2. Chọn một thư mục để duyệt ảnh bên trong. Chọn một ảnh để bắt đầu từ ảnh đó rồi xem tiếp các ảnh khác cùng thư mục. Nếu chọn nhiều ảnh, chỉ các ảnh được chọn sẽ được mở.
3. Chọn tệp ZIP để xem các ảnh được hỗ trợ, kể cả ảnh trong thư mục con của tệp nén. Bạn cũng có thể mở tệp từ Finder hoặc kéo ảnh và thư mục vào ứng dụng.

### Thư mục và mục yêu thích

Cây thư mục mở rộng từng thư mục khi cần. Bấm tên thư mục để mở, dùng mũi tên lên để về thư mục cha và làm mới sau khi thay đổi trong Finder. Ghim một thư mục phía trên cây để truy cập nhanh. Mở thư mục thông thường không tự động bao gồm mọi thư mục con.

### ZIP chỉ để đọc

Ảnh được giải nén vào thư mục tạm trong lúc tệp ZIP đang mở. Hãy xuất bản sao trước khi đổi tên hoặc sửa siêu dữ liệu gốc. Ứng dụng không ghi lại tệp ZIP. Hỗ trợ phương thức Stored/Deflate; không mở tệp nén mã hóa hoặc dùng phương thức khác. Giới hạn gồm tệp ZIP 2 GiB, 10.000 mục, 256 MiB cho mỗi mục sau giải nén và tổng dữ liệu giải nén 1 GiB.

### Trở về vị trí trước đó

Khi có thể, ứng dụng khôi phục bộ ảnh, ảnh đang chọn, chế độ xem và thiết lập tìm kiếm gần nhất. Nếu ổ đĩa bị ngắt kết nối hoặc quyền truy cập thay đổi, hãy dùng Mở… lần nữa. Các điều chỉnh ảnh và kết quả AI chưa lưu không được khôi phục.

### Điều cần biết

- Chọn thư mục cùng với các ảnh riêng lẻ sẽ tập hợp chúng mà không trùng lặp. Trong So sánh ảnh, Mở… thay đổi khung A hoặc B đang hoạt động và không bị khóa. Trợ giúp → Cách sử dụng cơ bản mở hướng dẫn ngắn ngay trong ứng dụng. Trợ giúp → Hướng dẫn chi tiết (GitHub) mở bản hướng dẫn đầy đủ theo ngôn ngữ của bạn trên GitHub bằng trình duyệt mặc định.

[Về đầu trang](#top)

---

<a name="viewer"></a>

## 2. Duyệt ảnh và xem tập trung

Trình xem có thể hiển thị từ một đến mười ảnh cùng lúc. Phóng to để kiểm tra chi tiết hoặc ẩn các điều khiển xung quanh để tập trung vào ảnh.

![Trình xem chính với các điều khiển bao quanh ảnh.](figures/viewer.png)

**Màn hình 01.** Trình xem chính với các điều khiển bao quanh ảnh.

1. **Chế độ xem** — Chuyển giữa Trình xem, Xem tất cả, Xem bản đồ và So sánh ảnh.
2. **Tìm và sắp xếp** — Tìm theo tên tệp, lọc định dạng, lọc nhãn và sắp xếp bộ ảnh đang mở.
3. **Điều khiển xem** — Chuyển ảnh, đặt mức thu phóng, đổi số ảnh hiển thị và chọn cách di chuyển ảnh.

### Các bước thực hiện

1. Chọn Trình xem ở phía trên. Dùng ← và → để chuyển ảnh. Đặt số ảnh mỗi màn hình bằng điều khiển số lượng hoặc \[ và \]; lưới sẽ thích ứng với hình dạng cửa sổ.
2. Chụm hoặc mở hai ngón tay trên bàn di chuột, hay dùng = và − để thu phóng. Nhấn 0 để Vừa cửa sổ và 1 để Kích thước thực. Chọn cách di chuyển ảnh từ các điều khiển phía dưới hoặc Cài đặt → Chung.
3. Nhấn F, bấm đúp ảnh hoặc nhấn nhanh Space để bật/tắt chế độ tập trung. Nhấn Esc để quay lại. Toàn màn hình là lệnh riêng, dùng ⌃⌘F.

### Chuyển nhiều ảnh cùng lúc

Trong trình xem thông thường, ←/→ chuyển theo số ảnh đã đặt cho mỗi màn hình. Khi hiển thị nhiều ảnh, ⌥←/⌥→ cũng chuyển một màn hình mỗi lần. Trong chế độ phân loại, phím mũi tên đơn chuyển từng ảnh, còn Option kết hợp mũi tên vẫn chuyển theo màn hình.

### Điều khiển di chuyển ảnh

Chọn kéo bằng nút trái, Space + kéo bằng nút trái, kéo bằng nút phải, nút giữa hoặc di chuyển bằng hai ngón tay trên bàn di chuột. Các phím ⌃⌥1–5 chọn cách di chuyển, không tự làm ảnh dịch chuyển. Vuốt ngang chuyển ảnh khi cử chỉ đó không được dùng để di chuyển ảnh phóng to.

### Điều khiển trong chế độ tập trung

Dấu × phía dưới chỉ ẩn thanh điều khiển nổi. Mở lại bằng nút cạnh tên tệp. Dấu × phía trên thoát chế độ tập trung. Các nút này vẫn dùng được khi ẩn tên tệp. Nhấn nhanh Space không đổi chế độ khi đang nhập chữ hoặc khi Space được gán phím tắt riêng.

### Điều cần biết

- Ảnh thu nhỏ có thể nằm bên trái, phải, trên, dưới hoặc được ẩn. Esc thoát chế độ xem tạm thời hiện tại trước khi đưa Trình xem thông thường về Xem tất cả.

[Về đầu trang](#top)

---

<a name="overview"></a>

## 3. Tìm và chọn ảnh trong Xem tất cả

Xem tất cả trải bộ ảnh hiện tại thành lưới ảnh thu nhỏ. Dùng chế độ này để nhìn qua thư mục, chọn ảnh cần dùng và chuẩn bị thao tác hàng loạt.

![Xem tất cả kết hợp lưới ảnh thu nhỏ với tìm kiếm, lựa chọn và điều chỉnh kích thước.](figures/overview.png)

**Màn hình 02.** Xem tất cả kết hợp lưới ảnh thu nhỏ với tìm kiếm, lựa chọn và điều chỉnh kích thước.

1. **Lưới ảnh thu nhỏ** — Bấm, chọn theo khoảng hoặc kéo qua các thẻ; bấm đúp để mở ảnh.
2. **Tìm kiếm và bộ lọc** — Thu hẹp bộ ảnh đang mở mà không thay đổi tệp.
3. **Kích thước và lựa chọn** — Điều chỉnh ảnh xem trước và dùng các thao tác dành cho ảnh đã chọn để xử lý hàng loạt.

### Các bước thực hiện

1. Chọn Xem tất cả hoặc nhấn G. Điều chỉnh thanh kích thước ảnh thu nhỏ để thấy nhiều ảnh hơn hoặc ảnh xem trước lớn hơn. Bấm đúp ảnh thu nhỏ để mở trong Trình xem.
2. Nhập vào Tìm theo tên tệp. Tìm kiếm không phân biệt chữ hoa/thường; mọi từ ngăn bằng dấu cách đều phải xuất hiện trong tên tệp. Chọn một hay nhiều định dạng, hoặc Tất cả định dạng để bỏ bộ lọc đó.
3. Bấm để chọn, ⌘-bấm để thêm hoặc bỏ một ảnh và ⇧-bấm để chọn một khoảng. Kéo hình chữ nhật từ ảnh hoặc vùng trống để chọn các thẻ giao với vùng đó.

### Phím hỗ trợ chọn ảnh

Giữ Shift khi bắt đầu kéo vùng chọn để thêm vào lựa chọn hiện có. Giữ ⌘ để đảo trạng thái chọn các ảnh trong vùng. Esc khôi phục lựa chọn trước khi kéo. ⌘A chọn mọi ảnh trong danh sách đang hiển thị.

### Sắp xếp danh sách hiện tại

Sắp xếp theo tên, ngày sửa đổi, ngày tạo, kích thước tệp hoặc hướng GPS. Sắp xếp tên đặt 2 trước 10. Sắp xếp GPS đọc siêu dữ liệu vị trí và đưa ảnh không có GPS xuống cuối. Điều kiện tìm kiếm, định dạng, nhãn và bản đồ kết hợp với nhau; không điều kiện nào thay đổi tệp gốc.

### Số thứ tự và kích thước xem trước

Nút # hiện hoặc ẩn số thứ tự ảnh thu nhỏ. Nhãn số quá lớn sẽ nằm ngoài ảnh nhỏ để không che ảnh. Kích thước ảnh thu nhỏ được ghi nhớ, với phạm vi 44,8–665,6 point; từng ô còn bị giới hạn bởi chiều rộng cửa sổ.

### Điều cần biết

- Tìm kiếm dựa trên tên tệp, không tìm vật thể, nội dung ảnh hay chữ OCR. Nếu không thấy ảnh mong đợi, hãy xóa tìm kiếm và các bộ lọc đang bật trước khi mở lại thư mục.

[Về đầu trang](#top)

---

<a name="compare"></a>

## 4. So sánh hai bộ ảnh

So sánh ảnh giữ hai bộ A và B độc lập, đặt cạnh nhau hoặc trên dưới. Chế độ này phù hợp để so phiên bản hoặc kiểm tra hai thư mục.

![Hai bộ ảnh trong So sánh ảnh.](figures/compare.png)

**Màn hình 03.** Hai bộ ảnh trong So sánh ảnh.

1. **Khung A và B** — Mỗi khung có bộ ảnh riêng và điều khiển Mở… riêng.
2. **Cách so sánh** — Chọn cách ghép ảnh, bên cần chuyển, lặp bên ít ảnh hơn và liên kết thu phóng.
3. **Khóa và ảnh thu nhỏ** — Cố định một bên hoặc chọn ảnh khác từ dải ảnh thu nhỏ của bên đó.

### Các bước thực hiện

1. Chọn So sánh ảnh hoặc nhấn ⌃⌥C. Dùng Chọn thư mục để so sánh… để lần lượt chọn A và B, hoặc dùng nút Mở… của từng khung.
2. Dùng Thứ tự danh sách để xem hai danh sách độc lập. Chọn Tên tệp trùng khớp để ghép tên không tính phần mở rộng: 001.jpg khớp với 001.png. Ảnh thiếu cặp vẫn có hàng so sánh với một bên trống.
3. Trong Chuyển ảnh, chọn Chỉ A, Cả hai hoặc Chỉ B. Dùng các mũi tên chung hoặc ảnh thu nhỏ của từng khung để chuyển. Bật Liên kết phóng to và di chuyển để xem các vị trí tương đối tương ứng.

### Chuyển ảnh và lặp

Chọn Chỉ A hoặc Chỉ B sẽ chuyển sang Thứ tự danh sách. Tên tệp trùng khớp trở lại cách chuyển theo cặp. Khi chọn Cả hai, Lặp bên ít ảnh hơn lặp danh sách ngắn trong lúc danh sách dài tiếp tục; khi tắt, danh sách ngắn giữ ảnh cuối. Chức năng lặp dùng cho Thứ tự danh sách.

### Khóa

Khóa cố định ảnh, mức thu phóng và vị trí di chuyển của một khung. Khóa B để duyệt A; khóa A để duyệt B. Mở khóa cả hai sẽ đưa đối tượng chuyển về Cả hai; khóa cả hai sẽ dừng chuyển ảnh. Vẫn có thể xem và cuộn dải ảnh thu nhỏ trong khung bị khóa.

### Ảnh gốc và trạng thái đã lưu

So sánh hiển thị ảnh gốc, không áp dụng các chỉnh sửa của trình xem thông thường. Hãy thoát so sánh để chỉnh sửa, xử lý hàng loạt hoặc đặt hình nền. Esc trở về chế độ xem trước đó. Bố trí, liên kết, tùy chọn chuyển ảnh cùng đầu vào và vị trí A/B gần nhất được ghi nhớ.

### Điều cần biết

- ⌥←/⌥→ chỉ chuyển A; ⇧⌥←/⇧⌥→ chỉ chuyển B. Tên tệp trùng khớp bỏ qua phần mở rộng, chữ hoa/thường và các cách biểu diễn Unicode tương đương.

[Về đầu trang](#top)

---

<a name="tags"></a>

## 5. Phân loại ảnh bằng bàn phím

Phân loại cho phép gắn nhiều nhãn riêng cho ảnh trong lúc duyệt. Nhãn là dấu trong ứng dụng, không phải thao tác thực hiện lên tệp gốc.

![Chế độ Phân loại với các phím được gán và dấu màu.](figures/tags.png)

**Màn hình 04.** Chế độ Phân loại với các phím được gán và dấu màu.

1. **Chế độ phân loại** — Bật hoặc tắt chế độ; khi tắt, các phím xem ảnh thông thường hoạt động trở lại.
2. **Các phím nhãn** — Dùng 1–4, QWER, ASDF hoặc bấm nút nhãn. Một ảnh có thể mang nhiều dấu.
3. **Bộ lọc nhãn** — Tập hợp ảnh phù hợp hoặc chưa gắn nhãn từ bộ ảnh đang mở.

### Các bước thực hiện

1. Mở ảnh rồi bấm Phân loại, dùng menu Nhãn ảnh hoặc nhấn ⌘⇧M. Trong So sánh ảnh, nhãn áp dụng cho ảnh ở khung đang hoạt động.
2. Duyệt bằng ← và →. Nhấn các vị trí phím 1–4, QWER hoặc ASDF để bật/tắt nhãn tương ứng. Nhấn lại để bỏ nhãn; một ảnh có thể có nhiều nhãn.
3. Thoát Phân loại bằng ⌘⇧M, Esc hoặc nút đóng của bảng. Dùng bộ lọc Nhãn để xem Có bất kỳ nhãn đã chọn nào, Có tất cả nhãn đã chọn hoặc Ảnh chưa gắn nhãn.

### Giữ nhịp duyệt ổn định

Gắn nhãn không tự chuyển sang ảnh tiếp theo. Trong chế độ Phân loại, danh sách đã lọc giữ nguyên để nhiều lần nhấn phím cùng tác động lên một ảnh. Kết quả lọc cập nhật khi thoát Phân loại. Trong chế độ này, phím mũi tên đơn chuyển từng ảnh.

### Ý nghĩa của các phím

Tên ban đầu, kể cả Xóa và Tải lên, chỉ là ví dụ. Các phím này không xóa, tải lên, di chuyển hay sửa ảnh. Bạn có thể đổi tên theo công việc, như Chọn để in hoặc Đã chỉnh sửa.

### Lưu trên máy

Nhãn đã gắn, tên và màu nhãn được lưu trong cơ sở dữ liệu cục bộ của ứng dụng và có lại sau khi mở ứng dụng lần nữa. Chúng tách biệt với EXIF và không đồng bộ qua XMP hay thư viện ảnh đám mây.

### Điều cần biết

- Khi Phân loại bật, các phím nhãn được ưu tiên hơn thao tác thông thường. Ví dụ, 1 và F gắn nhãn thay vì chọn Kích thước thực hay chế độ tập trung. Thoát Phân loại để dùng lại các phím tắt thông thường.

[Về đầu trang](#top)

---

<a name="tag-editor"></a>

## 6. Đặt tên, màu nhãn và hiểu giới hạn theo dõi ảnh

Đặt tên phù hợp công việc cho mười hai phím nhãn. Cùng một bộ tên áp dụng cho mọi thư mục; đổi tên không làm mất nhãn đã gắn.

![Trình sửa dùng chung cho tên và màu nhãn.](figures/tag-editor.png)

**Màn hình 05.** Trình sửa dùng chung cho tên và màu nhãn.

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

**Màn hình 06.** Xem bản đồ với các vùng có thể chọn và phần tóm tắt ảnh phù hợp.

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

Mở lựa chọn trong Trình xem hoặc Xem tất cả vẫn giữ giới hạn bản đồ. Các bộ lọc tên tệp, định dạng và nhãn cũng áp dụng. Xóa vùng bản đồ trở về danh sách lọc không giới hạn vị trí, gồm cả ảnh không có GPS. Mở một ảnh trên bản đồ nằm ngoài vùng chọn chỉ bỏ giới hạn địa lý.

### Tải và lưu trạng thái

Nền bản đồ cần kết nối internet. Ảnh không có GPS không xuất hiện dưới dạng ảnh thu nhỏ trên bản đồ. Đọc vị trí của bộ ảnh lớn có thể mất thời gian. Các vùng được khôi phục cùng phiên trước; mở thư mục mới sẽ xóa lựa chọn vùng cũ.

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

**Màn hình 07.** Bảng chỉnh sửa bên cạnh bản xem trước của ảnh hiện tại.

1. **Điều khiển chỉnh sửa** — Cắt, xoay, lật và điều chỉnh tông sáng, màu cùng chi tiết.
2. **Xem trước ảnh** — Kiểm tra kết quả hiện tại; dùng Kích thước thực khi điều chỉnh chi tiết.
3. **Xuất — phía dưới bảng** — Cuộn xuống trong bảng chỉnh sửa hoặc nhấn ⌘E để lưu bản sao trước khi đóng ứng dụng.

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

**Màn hình 08.** Cửa sổ chuyển đổi hàng loạt với định dạng, thu nhỏ đúng tỷ lệ và nơi lưu.

1. **Định dạng và chất lượng** — Chọn định dạng, chất lượng hoặc dùng thiết lập giảm dung lượng.
2. **Thu nhỏ đúng tỷ lệ** — Chọn giữ kích thước, cạnh dài nhất hoặc tỷ lệ phần trăm.
3. **Nơi lưu và xem trước** — Kiểm tra thư mục đích và tên đầu ra rồi bắt đầu chuyển đổi.

### Các bước thực hiện

1. Chọn ảnh bằng cách bấm, ⌘-bấm, ⇧-bấm hoặc ⌘A trên ảnh thu nhỏ; trong Xem tất cả còn có thể kéo vùng chọn. Có thể lọc theo nhãn trước. Trên bản đồ, dùng Ảnh trong vùng; menu của ghim có Ảnh này và Tất cả ảnh tại vị trí này.
2. Trong Đổi tên hàng loạt…, giữ hoặc thay tên, tìm và thay văn bản, thêm tiền tố, hậu tố và số thứ tự. Với Dùng tên phân loại, chọn rõ Phân loại dùng để đặt tên. Chỉ các tệp đã chọn thuộc phân loại đó được đổi tên. Kiểm tra danh sách tên cũ và mới trước khi áp dụng.
3. Trong Đổi định dạng, kích thước và nén hàng loạt…, chọn định dạng, chất lượng, kích thước ảnh và thư mục đích; kiểm tra tên đầu ra. Chia sẻ tệp… gửi các tệp gốc đã chọn tới bảng chia sẻ của macOS; Chia sẻ tệp đã hoàn tất… dùng các tệp xuất thành công. Dịch vụ chia sẻ khả dụng phụ thuộc macOS.

### Tên phân loại và số thứ tự

Dùng tên phân loại tạo tên như Tải lên01, Tải lên02 theo thứ tự danh sách. Tối đa 99 tệp dùng hai chữ số; từ 100 tệp dùng 001, 002; từ 1000 tệp tiếp tục tăng số chữ số. Ảnh có nhiều nhãn chỉ được xử lý một lần theo phân loại đã chọn; các tệp còn lại không đổi. Đánh số thông thường mặc định hai chữ số, cho phép đặt số đầu, bước tăng, số chữ số và dấu phân cách. Tên phân loại trống, tên không hợp lệ hoặc trùng đích sẽ ngăn áp dụng. Không đổi tên trực tiếp tệp trong ZIP.

### Định dạng, kích thước và dung lượng

Đổi phần mở rộng chỉ chỉnh chữ hoa/thường hoặc cách viết cùng định dạng như .jpg/.jpeg. Để đổi HEIC sang JPEG, dùng Đổi định dạng, kích thước và nén hàng loạt…. Cạnh dài nhất hoặc Tỷ lệ phần trăm thu nhỏ đúng tỷ lệ sau các điều chỉnh và cắt hiện tại; ảnh nhỏ không bị phóng to. Thiết lập giảm dung lượng dùng JPEG, cạnh dài 1920 pixel, chất lượng 75%. Dung lượng thực tế tùy ảnh và có thể lớn hơn tệp gốc.

### Ảnh gốc, kết quả và chia sẻ

Chuyển đổi áp dụng điều chỉnh hiện tại vào bản sao và giữ tệp gốc. Tên đầu ra đã có được thêm số. Ảnh động và nhiều trang chỉ lưu khung đầu. Dừng thao tác vẫn giữ tệp đã xong; kết quả báo số đã lưu, thất bại và chưa xử lý. Chia sẻ tệp gốc không bao gồm điều chỉnh chưa lưu. Muốn chia sẻ ảnh đã chỉnh hoặc thu nhỏ, hãy hoàn thành chuyển đổi rồi chia sẻ các tệp đã hoàn tất.

### Điều cần biết

- Kiểm tra số tệp và bản xem trước trước khi đổi tên. Đổi tên trong ứng dụng giữ liên kết nhãn; bản sao xuất ra là ảnh riêng, không tự kế thừa nhãn. Chọn đích và thao tác gửi trong bảng chia sẻ của macOS.

[Về đầu trang](#top)

---

<a name="quality"></a>

## 11. Hiểu phóng to AI, HDR và tải ảnh

Phóng to chất lượng cao thay cách nội suy khi hiển thị. Phóng to bằng AI tạo ảnh lớn hơn để lưu. Đầu ra HDR là tùy chọn hiển thị, không phải dấu xác nhận ảnh đang xem là HDR.

### Các bước thực hiện

1. Để hiển thị mượt hơn, bật Phóng to chất lượng cao. So sánh cạnh nhau hoặc trên dưới hiển thị cùng một ảnh với thu phóng và di chuyển liên kết; Esc đóng kiểu so sánh này.
2. Để tạo ảnh mới 2×, chọn ảnh, mở Phóng to bằng AI… rồi bấm Bắt đầu phóng to bằng AI. Kiểm tra bằng So sánh với ảnh gốc và Điểm ảnh thực tế, sau đó Lưu bản sao PNG….
3. Dùng HDR ON / HDR OFF để cho phép hoặc tắt hiển thị dải sáng mở rộng. Trong Cài đặt → Chung → Tải hình ảnh, chọn Ưu tiên, Thoải mái, Bình thường hoặc Chậm theo công việc.

### Đầu ra AI và giới hạn

Mô hình đi kèm chạy cục bộ qua Core ML; ảnh không được tải lên và không cần tải mô hình khi sử dụng. Chiều rộng và chiều cao đều tăng gấp đôi. Đầu ra là PNG sRGB SDR 8-bit, với độ trong suốt được nội suy riêng. Ảnh động dùng khung đầu, không bao gồm chỉnh sửa của trình xem. Đầu ra tối đa 64 triệu pixel và có thể thấp hơn trên Mac ít bộ nhớ. Lưu trước khi đóng; chi tiết do AI tạo là ước đoán.

### Định dạng và hiệu năng

Khả năng đọc và ghi phụ thuộc macOS đang chạy. Ứng dụng bổ sung giải mã QOI, các biến thể PCX phổ biến và cách hiển thị dự phòng cho SVG/SVGZ. Không bao gồm BPG và .clip. Thoải mái là chế độ tải mặc định. Mọi chế độ đều giảm tốc khi có áp lực bộ nhớ, nhiệt độ cao, tiết kiệm pin, ứng dụng khác hoặc bộ lưu trữ chậm.

### Điều cần biết

- Khi chuyển nhanh, bản xem trước nhỏ hoặc ảnh trước đó có thể còn hiển thị cho tới khi ảnh cuối sẵn sàng. Không có AI 4×, đầu ra AI HDR hay phóng to AI hàng loạt.

[Về đầu trang](#top)

---

<a name="slideshow"></a>

## 12. Phát album ảnh hoặc đặt hình nền

Album ảnh tự chuyển qua danh sách hiện tại trong chế độ tập trung một ảnh. Hình nền dùng bản sao riêng được chuẩn bị cho các màn hình đã chọn.

### Các bước thực hiện

1. Mở danh sách có ít nhất hai ảnh. Chọn Điều hướng → Album ảnh → Phát album ảnh hoặc nhấn ⌃⌥P.
2. Dùng các nút phát để tạm dừng. Chọn khoảng 1–300 giây và có lặp lại hay không từ điều khiển thời gian hoặc Cài đặt → Chung → Album ảnh.
3. Để đặt hình nền, trở lại trình xem thông thường rồi chọn Hình ảnh → Đặt ảnh hiện tại làm hình nền… hoặc nhấn ⌃⌥W. Chọn màn hình hiện tại hoặc mọi màn hình kết nối, Lấp đầy màn hình hoặc Hiển thị toàn bộ ảnh, và có áp dụng điều chỉnh hiện tại hay không; sau đó áp dụng.

### Cách phát

Mặc định là năm giây và bật lặp. Bộ đếm bắt đầu sau khi bản xem trước hoặc ảnh đã hiển thị, nên thời gian tải không lấy mất thời gian xem. Chuyển thủ công hoặc đổi khoảng thời gian sẽ khởi động lại bộ đếm. Nếu tắt lặp, phát dừng ở ảnh cuối.

### Tự động tạm dừng

Phát tạm dừng khi thoát chế độ tập trung, chuyển ứng dụng, máy ngủ hoặc bắt đầu thao tác tệp. Chỉ giữ màn hình thức trong khi phát. Mở ứng dụng lại khôi phục thiết lập nhưng không tự khởi động album.

### Bản sao hình nền

Ứng dụng tạo PNG mà không sửa nguồn. Ảnh động dùng khung đầu và HDR được chuẩn bị thành SDR. Bản sao không có EXIF/GPS, được định kích thước cho màn hình với tối đa 8192 pixel và giữ trong thư mục Application Support/Wallpapers của ứng dụng. Các không gian màn hình nền khác theo cách hoạt động của macOS. Bản sao cũ không tự xóa vì không gian khác có thể vẫn dùng.

### Điều cần biết

- Nếu không thể phát, kiểm tra danh sách đã lọc hiện tại có ít nhất hai ảnh và không đang bật Phân loại, So sánh ảnh hoặc một thao tác khác.

[Về đầu trang](#top)

---

<a name="settings"></a>

## 13. Thiết lập theo cách làm việc của bạn

Cài đặt tập hợp các lựa chọn xem thường ngày, phím tắt riêng, gán nhãn và liên kết tệp mặc định. Nhiều tùy chọn xem được tự khôi phục trong lần chạy sau.

![Cài đặt sắp xếp các tùy chọn chính trong bốn thẻ.](figures/settings.png)

**Màn hình 09.** Cài đặt sắp xếp các tùy chọn chính trong bốn thẻ.

1. **Các thẻ cài đặt** — Chung, Phím tắt, Nhãn ảnh và Liên kết tệp phụ trách các thiết lập khác nhau.
2. **Tùy chọn xem** — Đặt cách hiển thị, ảnh thu nhỏ, tên tệp, điều hướng và tải ảnh.
3. **Giải thích tại chỗ** — Đọc phần chữ dưới điều khiển hoặc di chuột lên đó để biết rõ cách hoạt động.

### Các bước thực hiện

1. Mở 알맹Re → Cài đặt…. Trong Chung, chọn đầu ra HDR/EDR, vị trí ảnh thu nhỏ, cỡ tên tệp, phóng to chất lượng cao, hiển thị cây thư mục và có duyệt vòng hay không.
2. Dùng Nhãn ảnh để lưu tên và màu chung, dùng Phím tắt để chọn phím và các phím bổ trợ. Di chuột lên điều khiển để đọc giải thích.
3. Để Finder mở các định dạng đã chọn bằng ứng dụng này, đặt 알맹Re.app ở vị trí ổn định như Applications, mở Liên kết tệp, chỉ chọn các nhóm định dạng mong muốn rồi áp dụng.

### Ngôn ngữ

Giao diện theo ngôn ngữ mà macOS gán cho ứng dụng. Đổi trong Cài đặt hệ thống → Cài đặt chung → Ngôn ngữ & Vùng → Ứng dụng. Ứng dụng hỗ trợ tiếng Hàn, Anh, Trung giản thể, Nhật, Pháp, Tây Ban Nha, Ả Rập và Việt; bộ hướng dẫn này gồm bảy ngôn ngữ.

### Các tùy chọn được ghi nhớ

Kích thước ảnh thu nhỏ, phóng to chất lượng cao, hiển thị tên tệp, tùy chọn tải, mục yêu thích, thiết lập nhãn và phím riêng được giữ lại. Bộ ảnh và vị trí xem gần nhất có thể khôi phục nếu tệp vẫn truy cập được. So sánh chất lượng phóng to bắt đầu ở trạng thái tắt sau khi chạy lại. Các chỉnh sửa hình ảnh và kết quả AI cần được xuất riêng.

### Liên kết tệp

Chỉ các nhóm định dạng được đánh dấu mới thay đổi. macOS có thể yêu cầu xác nhận. Di chuyển ứng dụng sau đó hoặc giữ các bản cũ có thể khiến Finder mở nhầm phiên bản; hãy áp dụng lại liên kết từ bản bạn muốn dùng.

### Điều cần biết

- Chung cũng liệt kê các định dạng gốc có trên Mac và có Xóa bộ nhớ đệm ảnh. Chọn chế độ tải chậm hơn nếu muốn giảm công việc nền khi dùng ứng dụng khác.

[Về đầu trang](#top)

---

<a name="shortcuts"></a>

## 14. Phím tắt và xử lý nhanh vấn đề

Bảng tham khảo tiếp theo liệt kê các phím thao tác mặc định và phím cố định theo ngữ cảnh. ⌘ là Command, ⌥ là Option, ⌃ là Control và ⇧ là Shift.

![Thẻ Phím tắt hiển thị các thao tác có thể gán và thông báo xung đột.](figures/shortcuts.png)

**Màn hình 10.** Thẻ Phím tắt hiển thị các thao tác có thể gán và thông báo xung đột.

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
| ← / → | Ảnh hoặc trang trước / tiếp theo | Có thể gán lại. Trình xem chuyển theo số ảnh mỗi màn hình; so sánh theo Chỉ A / Cả hai / Chỉ B. |
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
| 1 2 3 4 · Q W E R · A S D F | Bật/tắt mười hai nhãn ảnh | Vị trí phím vật lý cố định; chỉ dùng trong Phân loại. Tên và màu có thể sửa; các phím không xóa hay tải tệp lên. |
| ← / ↑ · → / ↓ | Ảnh trước / tiếp theo khi phân loại | Điều hướng cố định trong Phân loại, mỗi lần chuyển một ảnh. |
| ⌘A | Chọn mọi ảnh trong danh sách hiện tại | Phím chọn cố định khi ở ngoài So sánh ảnh; ô nhập chữ vẫn chọn văn bản như bình thường. |
| Esc | Hủy cử chỉ hiện tại hoặc thoát chế độ đang dùng | Cố định. Thoát Phân loại, so sánh, so sánh chất lượng phóng to hoặc tập trung; Trình xem thông thường trở về Xem tất cả. Cũng hủy cử chỉ chọn vùng. |

[Về đầu trang](#top)
