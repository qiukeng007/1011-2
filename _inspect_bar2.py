# -*- coding: utf-8 -*-
import os
out = []
root = r"D:\APP_DEMO\pospal_stock_app\lib"
for dirpath, dirs, files in os.walk(root):
    for f in files:
        if f.endswith(".dart"):
            fp = os.path.join(dirpath, f)
            raw = open(fp, "rb").read()
            for term in [b"Barcode.", b"barcode2d", b"BarcodeImage", b"barcodeData", b"BarcodeData", b"toImage", b"drawBarcode"]:
                idx = raw.find(term)
                if idx >= 0:
                    out.append(f"=== {fp} : {term.decode()} ===")
                    out.append(raw[max(0,idx-200):idx+400].decode("utf-8", errors="replace"))
                    out.append("")
open(r"D:\APP_DEMO\pospal_stock_app\_bar2_out.txt", "w", encoding="utf-8").write("\n".join(out))
print("done")
