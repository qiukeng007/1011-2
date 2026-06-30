import 'package:flutter_test/flutter_test.dart';

import 'package:pospal_stock_app/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PospalStockApp());
    expect(find.text('银豹库存查询'), findsOneWidget);
  });
}
