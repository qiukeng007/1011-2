# -*- coding: utf-8 -*-
import os
out = []
# pubspec deps
for fp in [r"D:\APP_DEMO\pospal_stock_app\pubspec.yaml",
           r"D:\APP_DEMO_4\smart_eye_stock\pubspec.yaml"]:
    raw = open(fp, "rb").read()
    out.append("=== " + fp + " ===")
    out.append(raw.decode("utf-8", errors="replace"))
    out.append("")

# search for barcode-related code in both projects
for root in [r"D:\APP_DEMO\pospal_stock_app\lib", r"D:\APP_DEMO_4\smart_eye_stock\lib"]:
    for dirpath, dirs, files in os.walk(root):
        for f in files:
            if f.endswith(".dart"):
                fp = os.path.join(dirpath, f)
                raw = open(fp, "rb").read()
                low = raw.lower()
                for term in [b"barcode_widget", b"barcode128", b"code128", b"ean13", b"barcode "]:
                    c = low.count(term)
                    if c:
                        out.append(f"{fp}: {term.decode()} x{c}")

open(r"D:\APP_DEMO\pospal_stock_app\_dep_out.txt", "w", encoding="utf-8").write("\n".join(out))
print("done")
