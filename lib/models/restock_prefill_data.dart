/// Data passed from QueryPage to RestockPage via HomePage
class RestockPrefillData {
  final String barcode;
  final String supplier;
  final String productName;
  final String specification;

  const RestockPrefillData({
    required this.barcode,
    this.supplier = '',
    this.productName = '',
    this.specification = '',
  });
}
