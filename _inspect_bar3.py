# -*- coding: utf-8 -*-
out = []
raw = open(r"D:\APP_DEMO\pospal_stock_app\lib\services\print_service.dart", "rb").read()
# find barcode generation section
for term in [b"code128", b"ean13", b"toSvg", b"toBytes", b"encodePng", b"Image.memory", b"img.Image"]:
    idx = raw.find(term)
    if idx >= 0:
        out.append("=== print_service " + term.decode() + " ===")
        out.append(raw[max(0,idx-250):idx+400].decode("utf-8", errors="replace"))
        out.append("")
open(r"D:\APP_DEMO\pospal_stock_app\_bar3_out.txt", "w", encoding="utf-8").write("\n".join(out))
print("done")
