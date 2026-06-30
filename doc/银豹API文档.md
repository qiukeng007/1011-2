# 银豹 POS API 文档（逆向工程）

> 来源：beta28.pospal.cn，2025-06 测试验证

## 基础信息

| 项目 | 值 |
|------|-----|
| 基础URL | `https://{host}.pospal.cn` |
| 测试站点 | `beta28.pospal.cn` |
| User-Agent | `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36` |
| 认证方式 | ASP.NET Cookie（`.POSPALAUTH` / `.ASPXAUTH`） |
| 编码 | UTF-8 |

## Cookie 管理

所有 API 请求需携带 Cookie，通过 `Set-Cookie` 响应头累积拼接。Cookie 约 1-2 小时过期，过期后需重新登录。

---

## 1. 登录流程

### 1.1 GET 登录页
```
GET /account/signin?ReturnUrl=%2fProduct%2fManage
```

- 获取初始 Cookie（`loginVersionStrForPospal`）
- 响应 200，HTML 页面

### 1.2 POST 登录
```
POST /account/SignIn
Content-Type: application/x-www-form-urlencoded
X-Requested-With: XMLHttpRequest
```

**参数：**
| 参数 | 值 | 说明 |
|------|-----|------|
| userName | `账号:工号` | 如 `thegeneralstore05:1001` |
| password | 工号密码 | |
| returnUrl | `/Product/Manage` | URL编码 |
| screenSize | `1080*1920` | |
| employeeSignin | `true` | 必须 |

**成功响应：**
```json
{"successed": true, "msg": "/Product/Manage?..."}
```

**失败响应：**
```json
{"successed": false, "msg": "工号或密码错误", "showVerification": false}
```

### 1.3 跟随重定向
```
GET {msg中的URL}
```
- 获取 `.POSPALAUTH` / `.ASPXAUTH` Cookie
- 至此登录完成

### 1.4 验证登录状态
```
GET /Product/Manage
Cookie: {累积的Cookie}
```

- 响应 200 = 已登录
- 响应 302 重定向到登录页 = 已过期
- 页面中包含 `var currentUserId = 3729448;` 提取 userId

---

## 2. 商品搜索

### 2.1 搜索条码
```
POST /Product/LoadProductsByPage
Content-Type: application/x-www-form-urlencoded
X-Requested-With: XMLHttpRequest
```

**参数：**
| 参数 | 值 | 说明 |
|------|-----|------|
| userId | 门店ID | 从 Product/Manage 提取 |
| enable | `1` | |
| productTagUidsJson | `[]` | |
| keyword | 条码数字 | 搜索关键词 |
| groupBySpu | `false` | |
| categorysJson | `[]` | |
| supplierUid | `` | |
| categoryType | `` | |
| pageIndex | `1` | |
| pageSize | `20` | |
| orderColumn | `` | |
| asc | `true` | |

**响应：**
```json
{
  "successed": true,
  "contentView": "<table>...</table>",
  "totalCount": 1
}
```

`contentView` 是 HTML 表格，结构：
```html
<thead>
  <th data="productImage"></th>
  <th data="name">商品名称</th>
  <th data="barcode">条码</th>
  <th data="stock">库存</th>
  <th data="sellPrice">销售价</th>
  <th data="buyPrice">进货价</th>
  ...
</thead>
<tbody>
  <tr data="2305041" data-uid="955837757463795171" data-editable="1">
    <td>1</td>
    <td><a class="btnShowEditArea">编辑</a></td>
    <td></td>
    <td>商品名称</td>
    <td>条码</td>
    ...
  </tr>
</tbody>
```

**关键字段：**
- `<tr data="..."` — `data` 属性的值是 `productId`（用于 FindProduct）
- `<tr data-uid="..."` — `data-uid` 的值是产品 UID
- 第2个 `<td>` 中的 `<a class="btnShowEditArea">` 是编辑按钮
- 列头 `<th data="xxx">` 的 `data` 属性值动态映射列索引

**常见列名（data属性）：**
`name, barcode, attribute4(货号), extBarcode(扩展码), brandName(品牌), attribute6(规格), pinyin(拼音码), categoryName(分类), stock(库存), baseUnitName(主单位), sellPrice(销售价), buyPrice(进货价), wholeSalePrice(批发价), memberPrice(会员价), supplierName(供货商), createDate(创建日期)`

---

## 3. 商品详情

### 3.1 获取完整商品数据
```
POST /Product/FindProduct
Content-Type: application/x-www-form-urlencoded
X-Requested-With: XMLHttpRequest
```

**参数：**
| 参数 | 值 |
|------|-----|
| productId | `2305041`（来自搜索结果 `<tr data="...">`) |

**响应：**
```json
{
  "product": {
    "stock": 0.0,
    "stockQuantity": 0.0,
    "updateStock": 0.0,
    "barcode": "9180920041244",
    "name": "Make-up box",
    "uid": "955837757463795171",
    "buyPrice": 580.00,
    "sellPrice": 580.00,
    "baseUnitName": "BOX",
    "supplierName": "...",
    "category": "...",
    ...
  },
  "showType": "...",
  "moreSpecProducts": [],
  "caseproductItems": []
}
```

**库存相关字段：**
| 字段 | 类型 | 说明 |
|------|------|------|
| `stock` | double | **主库存**（修改这个） |
| `stockQuantity` | double | 库存数量 |
| `updateStock` | double | 更新库存？ |
| `isOutOfStock` | bool | 是否缺货 |
| `ignoreStock` | bool | 忽略库存 |
| `isEnableVirtualStock` | bool | 虚拟库存 |
| `InitStock` | double | 初始库存 |
| `ChangedOccupiedQuantity` | double | 变更占用数 |
| `CanSaleAreaStockOrStock` | double | 可售区域库存 |

---

## 4. 修改库存 ⭐

### 4.1 完整流程

```
1. 搜索条码 → 获取 productId (<tr data="...">)
2. FindProduct → 获取完整 product JSON
3. 修改 product.stock = 目标值
4. SaveProduct → 提交修改
```

### 4.2 SaveProduct API
```
POST /Product/SaveProduct
Content-Type: application/x-www-form-urlencoded
X-Requested-With: XMLHttpRequest
```

**参数：**
| 参数 | 值 | 说明 |
|------|-----|------|
| userId | 门店ID | |
| productJson | JSON字符串 | 完整商品对象（从 FindProduct 获取，修改后序列化） |

**productJson 必含字段（推测）：**
- `uid` — 商品唯一ID
- `stock` — 目标库存值
- `barcode` — 条码（不可与其他商品重复）
- `name` — 商品名
- 其他所有从 FindProduct 获取的字段（保持原值）

**成功响应：**
```json
{"successed": true, "syncStores": [], "stores": []}
```

**失败响应示例：**
```json
{"successed": false, "msg": "商品条码已被使用，请重新填写条码！"}
```

### 4.3 Dart/Flutter 实现伪代码
```dart
// 1. 搜索条码
final searchResp = await post('/Product/LoadProductsByPage', {
  'userId': userId,
  'keyword': barcode,
  ...
});
// 从 HTML 提取 productId
final productId = RegExp(r'<tr\s+data="(\d+)"').firstMatch(searchResp['contentView'])!.group(1)!;

// 2. 获取完整商品
final findResp = await post('/Product/FindProduct', {
  'productId': productId,
});
var product = findResp['product'];

// 3. 修改库存
product['stock'] = newStockValue;

// 4. 保存
final saveResp = await post('/Product/SaveProduct', {
  'userId': userId,
  'productJson': jsonEncode(product),
});
// saveResp['successed'] == true → 成功
```

---

## 5. 编辑页面机制

### 5.1 编辑入口
搜索结果每行第2个 `<td>` 包含编辑按钮：
```html
<a data-editable="1" class="operation2 btnShowEditArea">编辑</a>
```

### 5.2 编辑流程（JS源码分析）
来自 `website.product.manage.js`：

```javascript
// 点击编辑按钮
$(".btnShowEditArea").bind("click", function () {
    var productId = $(this).parent().parent().attr("data");
    if (hasNewProductInfoAuth) {
        // 新版 → 打开独立页面
        pospal.openPage("/ProductInfo/Retail?productId=" + productId, false);
    } else {
        // 旧版 → 内联编辑
        editProduct.findProduct(productId);
    }
});

// findProduct 调用 FindProduct API
findProduct: function (productId) {
    pospal.ajax({
        url: "/Product/FindProduct",
        data: { "productId": productId },
        success: function (result) {
            var product = result.product;
            this.bindProduct(product, ...);
        }
    });
}

// saveProduct 保存
saveProduct: function () {
    var product = this.buildProductFromForm();
    var data = { "productJson": JSON.stringify(product) };
    // 单商品：POST /Product/SaveProduct
    // 多颜色尺码：POST /Product/SaveProducts
}
```

### 5.3 编辑页面DOM关键ID
- `#editArea` — 编辑区域容器
- `#edit_stock` — 库存输入框
- `#edit_barcode` — 条码输入框
- `#edit_name` — 名称输入框
- `#edit_sellPrice` — 售价输入框
- `#edit_buyPrice` — 进价输入框
- `.btnShowEditArea` — 编辑按钮（搜索结果行内）

---

## 6. 已发现的完整API列表

| 端点 | 方法 | 说明 |
|------|------|------|
| `/account/signin` | GET | 登录页 |
| `/account/SignIn` | POST | 提交登录 |
| `/Product/Manage` | GET | 商品管理主页 |
| `/Product/LoadProductsByPage` | POST | 搜索商品列表 |
| `/Product/LoadProductSummary` | POST | 搜索匹配数量 |
| `/Product/FindProduct` | POST | 获取单个商品完整数据 |
| `/Product/SaveProduct` | POST | 保存单个商品（含库存） |
| `/Product/SaveProducts` | POST | 批量保存（多颜色尺码） |
| `/Product/SaveProductColorSizeGroup` | POST | 保存颜色尺码组 |
| `/Product/SaveProductColorSizeBase` | POST | 保存颜色尺码基础 |
| `/Product/LoadProductColorSizes` | POST | 加载颜色尺码 |
| `/Product/GetProductColorSizeBase` | POST | 获取颜色尺码基础 |
| `/Product/LoadMulColorSizeProductsDetail` | POST | 多颜色尺码明细 |
| `/Product/UploadProductImage` | POST | 上传商品图片 |
| `/Product/SaveGroupsSort` | POST | 保存分组排序 |
| `/Product/SaveCopyProductsUserJobCondition` | POST | 复制商品 |
| `/Product/SaveStorePrinters` | POST | 保存门店打印机 |
| `/Product/SaveUserLabelPrinters` | POST | 保存用户标签打印机 |
| `/Product/SaveImageWithSegmentation` | POST | 保存图片分割 |
| `/Product/SaveUserJobCondition` | POST | 保存用户工作条件 |
| `/Product/SaveCustomAttribute` | POST | 保存自定义属性 |
| `/Product/SaveProductBarcodeGenerationRule` | POST | 条码生成规则 |
| `/Export/Product` | POST | 导出商品 |
| `/ProductInfo/Retail` | GET | 新版零售商品编辑页 |
| `/ProductInfo/Catering` | GET | 新版餐饮商品编辑页 |

---

## 7. 关键JS文件

| 文件 | 大小 | 说明 |
|------|------|------|
| `website.product.manage.js` | 655KB | 商品管理核心逻辑（搜索/编辑/保存） |
| `website.layout.js` | — | 页面布局 |
| `pospal.js` | — | 银豹通用库（ajax/UI等） |

---

## 8. 测试验证记录

- **日期**: 2026-06-07
- **测试站点**: beta28.pospal.cn
- **测试账号**: thegeneralstore05:1001
- **测试商品**: Make-up box (9180920041244)
- **库存修改**: 0 → 1 ✅ 成功
- **SaveProduct响应**: `{"successed":true}`
- **验证**: 重新搜索后库存显示为 1

---

## 9. 安全注意事项

1. **Cookie 有效期**: 约 1-2 小时，过期后返回 302 到登录页
2. **权限**: 工号权限决定能否编辑库存（`hasEditProductAuth` 等标志）
3. **并发**: 多设备同时编辑同一商品可能冲突
4. **审计**: 所有修改有服务端日志
5. **条码唯一性**: 修改商品时必须确保条码不与其他商品重复
