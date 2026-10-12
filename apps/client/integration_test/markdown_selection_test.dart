import 'package:integration_test/integration_test.dart';

import '../test/markdown_selection_test.dart' as markdown;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  markdown.main();
}
