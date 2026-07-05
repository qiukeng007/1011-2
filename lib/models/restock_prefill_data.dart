/// Data passed from QueryPage to RestockPage via HomePage
class RestockPrefillData {
  final String barcode;
  final String supplier;
  final String productName;
  final String specification;
  final double? buyPrice;
  final double? sellPrice;

  const RestockPrefillData({
    required this.barcode,
    this.supplier = '',
    this.productName = '',
    this.specification = '',
    this.buyPrice,
    this.sellPrice,
  });
}
