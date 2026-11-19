# AlmaengRe performance testing

[한국어](ko.md) · **English** · [简体中文](zh-Hans.md) · [Русский](ru.md) · [Français](fr.md)

This report covers the benchmarks that informed AlmaengRe 1.2 (build 110), and the sidebar experiments that followed. The November tests ran on an Apple M3 with 24 GiB of unified memory and macOS 15.7.5. The M2 with 16 GiB remains a target for hardware testing.

| Test | What we measured and decided |
| --- | --- |
| Build 97, large-library baseline | 1,261 regression tests passed, 36 were skipped. Thumbnails rendered for 792 of 805 nonempty files. The other 13 were video cases limited by native handling on the test Mac. The mixed-use session lasted 1,864.30 s and included 343 actions. [Full build 97 report in Korean](../validation/1.0.42-performance-qa.ko.md) |
| Builds 105–106, opening and scrolling | With 729 items and 717 prepared thumbnails, the four foreground runs took 1.482–1.759 s on 105 and 1.426–1.686 s on 106 to generate refined thumbnails for 25 visible items and drain the queue after sizing. Ranges overlapped. We excluded runs that lost foreground focus or hit the memory guard from direct speed comparisons. |
| Builds 106–107, returning to a RAW page | In six-image view, the repeated 106 control needed 1,056–1,189 ms to publish all refined frames after returning. Build 107 needed 92–215 ms, with zero additional refined renders after the first 12 images. Across the initial display and round trips, CPU time went from 18.09 to 9.03 s and peak sampled app memory went from 1,401 to 1,219 MiB in that pair. The change repartitioned the existing 128 MiB cache budget in views with at least five images. |
| Builds 107–108, resizing thumbnails | With the same 729-item view and pointer gesture, the largest excess main-loop gap was 1,481–1,552 ms on 107 and 816–895 ms on 108. The slider kept updating while grid resizing was deferred. The total measured gesture and settling sequence increased slightly in these runs. |
| Builds 108–109, applying and clearing EXIF filters | In the matched foreground pair, the worst of four EXIF update gaps fell from 628 to 598 ms. The first search still took about 4.4 s end to end. We verified the results, order and retained selection. |
| Builds 109–110, resizing thumbnails again | After simplifying footer layout, the largest excess main-loop gap per run fell from 670–944 ms to 441–449 ms. The matched gesture went from 226.4 to 78.206 pt. All 25 visible thumbnails met the 256 px check at the final size. |
| Build 110, RAW and video together | With five RAW images and one video visible, independent video output stayed near 60 fps. The largest observed main-thread gaps were 433–512 ms during direct sidebar scrolling and 573–606 ms during combined scrolling, RAW selection and zoom. |
| Build 111 experiments, sidebar | A row-reuse prototype reduced the direct-scroll gap to 48.5–49.2 ms, but triggered 12 AppKit warnings for reentrant table operations during the 729-item filter test. Fixed-size rows and a single-column grid delivered no consistent improvement in combined use. The visible-rows prototype increased the combined gap to 825–898 ms. Release 1.2 uses build 110. |

## How to read the results

We matched the file list, prepared thumbnails, viewport and input sequence within each direct comparison. Where possible, we reversed run order and used separate test settings and caches. Resource-guarded runs monitored system memory pressure, sampled app memory and swap. The completed build 110 mixed-use comparison kept normal memory pressure and recorded zero swap growth. Cache budgets apply to cached data. Sampled process memory also includes decoded images, codecs and rendering work.

Frame publication, timer gaps and independent video output are separate measurements. They give no direct reading of physical display latency or compositor frame drops. The reported ranges reflect the observed runs. Remaining checks include long mixed sessions on M2 with 16 GiB, responsiveness of other apps and keeping a deep selection in view when resizing the grid.

[Selected measurements as CSV](measurements.csv) · [AlmaengRe 1.2 release](https://github.com/SeederPowerDrop/AlmaengRe/releases/tag/v1.2)
