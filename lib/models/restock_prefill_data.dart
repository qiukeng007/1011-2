/// Data passed from QueryPage to RestockPage via HomePage
class RestockPrefillData {
  final String barcode;
  final String? uid;
  final String supplier;
  final String productName;
  final String specification;
  final double? buyPrice;
  final double? sellPrice;
  final String? imageUrl;

  const RestockPrefillData({
    required this.barcode,
    this.uid,
    this.supplier = '',
    this.productName = '',
    this.specification = '',
    this.buyPrice,
    this.sellPrice,
    this.imageUrl,
  });
}
