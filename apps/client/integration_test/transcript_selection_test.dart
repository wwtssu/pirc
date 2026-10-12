import 'package:integration_test/integration_test.dart';

import '../test/transcript_list_test.dart' as transcript;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Use in-memory sessions so native selection checks do not take over the
  // user's connected computer or alter saved connections.
  transcript.main();
}
