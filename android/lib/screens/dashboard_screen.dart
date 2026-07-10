import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:itrack_fe/state/auth_state.dart';
import 'package:itrack_fe/state/dashboard_state.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/utils/constants.dart';
import 'package:itrack_fe/screens/new_installation_screen.dart';
import 'package:itrack_fe/screens/tracker_detail_screen.dart';
import 'package:itrack_fe/widgets/empty_state.dart';
import 'package:itrack_fe/widgets/tracker_card.dart';

/// FE home: three status buckets (Unassigned / Ongoing / Completed),
/// client-side search, pull-to-refresh, live updates, FAB → new installation.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  late final DashboardState _state;
  final _searchController = TextEditingController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state = DashboardState();
    final user = context.read<AuthState>().user!;
    _state.start(user);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Force a refresh when the app returns to the foreground.
    if (state == AppLifecycleState.resumed) {
      _state.refresh(silent: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _state,
      child: Consumer<DashboardState>(
        builder: (context, state, _) {
          return Scaffold(
            appBar: AppBar(
              title: _searching
                  ? TextField(
                      controller: _searchController,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Colors.white,
                      decoration: const InputDecoration(
                        hintText: 'Search SDWAN ID, customer, SIM…',
                        hintStyle: TextStyle(color: Colors.white70),
                        border: InputBorder.none,
                      ),
                      onChanged: state.setSearch,
                    )
                  : const Text('My Installations'),
              actions: [
                IconButton(
                  icon: Icon(_searching ? Icons.close : Icons.search),
                  onPressed: () {
                    setState(() => _searching = !_searching);
                    if (!_searching) {
                      _searchController.clear();
                      state.setSearch('');
                    }
                  },
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'logout') _confirmLogout();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'user',
                      enabled: false,
                      child: Text(
                        context.read<AuthState>().user?.name ?? 'Field Engineer',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const PopupMenuItem(
                        value: 'logout', child: Text('Logout')),
                  ],
                ),
              ],
            ),
            body: Column(
              children: [
                _BucketTabs(state: state),
                Expanded(child: _buildList(state)),
              ],
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const NewInstallationScreen()),
                );
                _state.refresh(silent: true);
              },
              icon: const Icon(Icons.add),
              label: const Text('New'),
            ),
          );
        },
      ),
    );
  }

  Widget _buildList(DashboardState state) {
    if (state.loading && state.visibleTrackers.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.visibleTrackers.isEmpty) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: 'Could not load installations',
        subtitle: state.error,
        onRetry: () => state.refresh(),
      );
    }
    final trackers = state.visibleTrackers;
    return RefreshIndicator(
      onRefresh: () => state.refresh(),
      child: trackers.isEmpty
          ? ListView(
              children: const [
                SizedBox(height: 120),
                EmptyState(
                  icon: Icons.inbox,
                  title: 'Nothing here',
                  subtitle: 'Pull down to refresh, or tap + to create one.',
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: trackers.length,
              itemBuilder: (context, i) {
                final tracker = trackers[i];
                return TrackerCard(
                  tracker: tracker,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            TrackerDetailScreen(trackerId: tracker.id),
                      ),
                    );
                    _state.refresh(silent: true);
                  },
                );
              },
            ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Logout')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<AuthState>().logout();
    }
  }
}

/// The three bucket tabs with live count badges.
class _BucketTabs extends StatelessWidget {
  final DashboardState state;
  const _BucketTabs({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          _tab(context, TrackerBucket.unassigned, 'Unassigned', Icons.schedule),
          _tab(context, TrackerBucket.ongoing, 'Ongoing', Icons.sync),
          _tab(context, TrackerBucket.completed, 'Done', Icons.check_circle),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, TrackerBucket bucket, String label,
      IconData icon) {
    final selected = state.bucket == bucket;
    final count = state.countFor(bucket);
    return Expanded(
      child: GestureDetector(
        onTap: () => state.setBucket(bucket),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppTheme.primary : AppTheme.badgeBg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Icon(icon,
                  size: 18,
                  color: selected ? Colors.white : AppTheme.badgeText),
              const SizedBox(height: 3),
              Text(
                '$label ($count)',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppTheme.badgeText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
