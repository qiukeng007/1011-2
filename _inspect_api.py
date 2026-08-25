# -*- coding: utf-8 -*-
import os
out = []
base = r"C:\Users\wenzi\AppData\Local\Pub\Cache\hosted\pub.flutter-io.cn\barcode-2.2.9\lib\src"
# find Barcode class main file
for f in os.listdir(base):
    if f.endswith(".dart"):
        fp = os.path.join(base, f)
        raw = open(fp, "rb").read()
        if b"class Barcode" in raw or b"Uint8List toBytes" in raw or b"toBytes" in raw and b"class " in raw:
            out.append("=== " + f + " ===")
            for term in [b"toBytes", b"toSvg", b"class Barcode"]:
                idx = raw.find(term)
                if idx >= 0:
                    out.append("--- " + term.decode() + " ---")
                    out.append(raw[max(0,idx-100):idx+400].decode("utf-8", errors="replace"))
                    out.append("")
open(r"D:\APP_DEMO\pospal_stock_app\_api_out.txt", "w", encoding="utf-8").write("\n".join(out))
print("done")
