# -*- coding: utf-8 -*-
out = []
# print_service.dart barcode rendering
raw = open(r"D:\APP_DEMO\pospal_stock_app\lib\services\print_service.dart", "rb").read()
idx = raw.find(b"Barcode")
if idx >= 0:
    out.append("=== print_service Barcode context ===")
    out.append(raw[max(0,idx-300):idx+800].decode("utf-8", errors="replace"))
    out.append("")

# printer_widgets.dart
raw2 = open(r"D:\APP_DEMO\pospal_stock_app\lib\widgets\printer_widgets.dart", "rb").read()
for term in [b"Barcode", b"code128", b"Code128", b"ean13"]:
    idx = raw2.find(term)
    if idx >= 0:
        out.append("=== printer_widgets " + term.decode() + " ===")
        out.append(raw2[max(0,idx-200):idx+500].decode("utf-8", errors="replace"))
        out.append("")

open(r"D:\APP_DEMO\pospal_stock_app\_bar_out.txt", "w", encoding="utf-8").write("\n".join(out))
print("done")
