import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/utils/constants.dart';
import 'package:itrack_fe/utils/status_maps.dart';

void main() {
  test('dashboard bucket rules match the web app', () {
    expect(bucketForStatus('waiting_noc_assignment'), TrackerBucket.unassigned);
    expect(bucketForStatus('installation_complete'), TrackerBucket.completed);
    expect(bucketForStatus('completed'), TrackerBucket.completed);
    // Anything mid-workflow is "ongoing".
    expect(bucketForStatus('ready_for_coordination'), TrackerBucket.ongoing);
    expect(bucketForStatus('hso_submitted'), TrackerBucket.ongoing);
  });

  test('status map covers key FE statuses with non-Unknown labels', () {
    expect(statusInfoFor('waiting_noc_assignment').label, 'Pending');
    expect(statusInfoFor('installation_complete').label, 'Done');
    // Statuses the web map omitted are still handled here.
    expect(statusInfoFor('hso_submitted').label, isNot('Unknown'));
  });

  testWidgets('theme builds without error', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: Text('iTrack')),
    ));
    expect(find.text('iTrack'), findsOneWidget);
  });
}
