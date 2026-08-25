# -*- coding: utf-8 -*-
with open(r"D:\APP_DEMO\pospal_stock_app\lib\pages\query_page.dart", "rb") as f:
    raw = f.read()

changes = 0

# Edit 1: Add suffixIcon
old1 = b"                        border: OutlineInputBorder(\r\n                          borderRadius: BorderRadius.circular(AppConstants.radiusSm),\r\n                        ),\r\n                      ),"
new1 = b"                        border: OutlineInputBorder(\r\n                          borderRadius: BorderRadius.circular(AppConstants.radiusSm),\r\n                        ),\r\n                        suffixIcon: IconButton(\r\n                          icon: const Icon(Icons.search, size: 22),\r\n                          onPressed: () => _query(_barcodeController.text),\r\n                        ),\r\n                      ),"

c = raw.count(old1)
if c == 1:
    raw = raw.replace(old1, new1)
    changes += 1
    print("Edit 1 (search icon): OK")
else:
    print(f"Edit 1 FAIL: {c}")

# Edit 2: GestureDetector wrapping SingleChildScrollView
old2 = b"        SingleChildScrollView(\r\n          controller: _scrollController,\r\n          padding: const EdgeInsets.all(12),"
new2 = b"        GestureDetector(\r\n          onTap: () => FocusScope.of(context).unfocus(),\r\n          child: SingleChildScrollView(\r\n            controller: _scrollController,\r\n            padding: const EdgeInsets.all(12),"

c2 = raw.count(old2)
if c2 == 1:
    raw = raw.replace(old2, new2)
    changes += 1
    print("Edit 2 (GestureDetector start): OK")
else:
    print(f"Edit 2 FAIL: {c2}")

# Edit 2b: Close GestureDetector after SingleChildScrollView
old2b = b"        ),\r\n\r\n        // \xe5\xba\x95\xe9\x83\xa8\xe6\x8c\x89\xe9\x92\xae"
new2b = b"        ),\r\n      ),\r\n\r\n        // \xe5\xba\x95\xe9\x83\xa8\xe6\x8c\x89\xe9\x92\xae"

c2b = raw.count(old2b)
if c2b == 1:
    raw = raw.replace(old2b, new2b)
    changes += 1
    print("Edit 2b (GestureDetector close): OK")
else:
    print(f"Edit 2b FAIL: {c2b}")

with open(r"D:\APP_DEMO\pospal_stock_app\lib\pages\query_page.dart", "wb") as f:
    f.write(raw)

print(f"\nTotal: {changes}/3")
print(f"Brackets: {raw.count(b'{')}/{raw.count(b'}')}")
