# ITrack — Analysis, Issues & Improvement Roadmap

---

## Current Concept

### What It Does
A Flask + MongoDB + Socket.IO web app that tracks the full lifecycle of SD-WAN router installations. Two primary user planes:
- **FE (Field Engineer)** — mobile-first, creates trackers on-site and drives the physical installation.
- **NS (NOC Support)** — desktop, handles backend provisioning (SIM, ZTP, HSO approval).

### Lifecycle (as implemented)
```
FE creates tracker
  └── NOC assigns to NS
        └── NS activates SIM1, SIM2
              └── NS verifies ZTP config
                    └── FE or NS executes ZTP pull
                          └── Chat unlocks (FE-NS coordination)
                                └── FE submits HSO docs
                                      └── NS approves → COMPLETE
```

### Real-Time Architecture (as implemented)
- Socket.IO rooms: `tracker_{id}`, `dashboard_{role}`, `user_{user_id}`
- Server broadcasts full tracker payload on every state change (`SOCKET_INCLUDE_FULL_DATA`)
- Client-side: `handleFETrackerUpdate` / `handleNOCTrackerUpdate` in templates, `realtime_handler.js` as shared utility
- Fallback: if no Socket.IO data, calls `loadTracker()` (REST API fetch)
- Dashboard: listens for `dashboard_update` events → debounced full list reload

### KPI Architecture (as implemented)
- `stage_timestamps` sub-document on each tracker — dedicated timestamps stamped on first occurrence of each stage transition (not derived from events)
- `calculate_stage_times()` computes durations from these fields
- `/api/analytics/kpi` returns averages for: queue wait, SIM1/SIM2 activation, ZTP config, ZTP execution, NS processing, HSO review, total completion
- Analytics are computed in Python by loading all matching trackers and iterating

---

## What's Good

- **Room-based Socket.IO** — the `tracker_{id}` room design is correct; only users viewing that tracker get updates.
- **Full tracker in broadcast payload** — sending complete tracker data with each Socket.IO event avoids a round-trip API call on the receiving end.
- **Dedicated `stage_timestamps`** — storing KPI timestamps as flat fields (not derived from events) is a deliberate, correct choice. Makes aggregation fast without event array scanning.
- **`make_event()` helper** — every state change goes through a single function, ensuring consistent event structure (actor, role, timestamp, metadata).
- **`calculate_stage_times()` reuse** — used by both KPI endpoint and export, single source of truth for duration calculations.
- **Hybrid mode env var** — `REALTIME_MODE` allows fallback without code changes.
- **HSO attempt history** — `hso.attempts[]` array preserves the full approval/rejection history.
- **SIM attempt history** — `sim.sim1.attempts[]` similarly tracks retries.

---

## What's Broken

### 1. `user_id` Missing from `join_dashboard` — User Notifications Are Dead

**Problem**: The `join_dashboard` handler in `app.py` requires both `user_id` and `role` to register the `user_{user_id}` room. But both `fe_dashboard.html` and `noc_dashboard.html` emit:
```javascript
socket.emit('join_dashboard', { role: '{{ session.role }}' });  // no user_id
```
`user_id` is `None` on the server, so `join_room(f"user_{user_id}")` is never called from a dashboard page. `broadcast_to_user()` only reaches users currently on a tracker detail page who happen to have joined a tracker room — not their personal notification room.

**Impact**: Transfer request notifications, reassignment confirmations, and any other user-targeted events are silently dropped on the dashboard.

**Fix**: Pass `user_id` in the `join_dashboard` emit.

---

### 2. No Reconnect Handling — Real-Time Silently Breaks

**Problem**: Neither dashboard nor tracker detail templates listen for the Socket.IO `connect` event to re-join rooms after a reconnection. When a connection drops (network blip, server restart), the client auto-reconnects but its room memberships are gone. Updates stop arriving with no indication to the user.

**Impact**: A field engineer or NOC operator can be working on a live tracker and unknowingly be stale for an entire session.

**Fix**: Add a `socket.on('connect', ...)` handler in each template that re-emits `join_tracker` / `join_dashboard` with the appropriate IDs.

---

### 3. `realtime_handler.js` Functions Are Never Called

**Problem**: `realtime_handler.js` exports `updateTrackerUI()`, `updateSIMStatus()`, `updateZTPStatus()`, `updateHSOStatus()`, etc. — a comprehensive set of DOM updaters. However, `handleFETrackerUpdate` and `handleNOCTrackerUpdate` in the templates do NOT call `updateTrackerUI()`. They call the page-local `renderAll()` (which re-renders the entire page from data) or `loadTracker()` (which makes an API call).

**Impact**: The handler library exists but does nothing. The `renderAll()` path is correct and complete, but `realtime_handler.js` is dead weight. This creates confusion about which update path is active.

**Fix**: Either fully wire `realtime_handler.js` into the templates (replacing `renderAll()` with targeted DOM updates for zero-flicker), or delete it and formalize `renderAll()` as the single update path.

---

### 4. Dashboard `tracker_update` Listener Is Dead Code

**Problem**: Both `noc_dashboard.html` and `fe_dashboard.html` listen for `socket.on('tracker_update', ...)`. But dashboards only join `dashboard_{role}` rooms. The server only emits `tracker_update` to `tracker_{id}` rooms. These listeners will never fire.

**Fix**: Remove the `tracker_update` listener from both dashboard templates. The `dashboard_update` listener is the correct one.

---

### 5. Dashboard Updates Are Full List Reloads

**Problem**: On any `dashboard_update` event, both dashboards call `debouncedReload()` which re-fetches the entire tracker list from the API. Every status change by any user causes every connected user of that role to reload their full list.

**Impact**: At scale this means N connected FE users all hit the API simultaneously every time any tracker changes. Also causes visible list flicker on the dashboard.

**Fix**: The `dashboard_update` payload already carries `tracker_id` and event data. The dashboard should do a targeted update — insert, remove, or update the specific tracker card in the list DOM rather than refetching everything.

---

### 6. `debug=True` in Production Entry Point

**Problem**: `socketio.run(app, debug=True, ...)` in `app.py`. Debug mode enables the Werkzeug debugger (remote code execution risk), auto-reloader, and verbose tracebacks.

**Fix**: Gate it: `debug=os.environ.get('FLASK_DEBUG', 'false').lower() == 'true'`.

---

### 7. Chat Files Stored as Base64 in MongoDB Documents

**Problem**: Uploaded chat images and audio are base64-encoded and stored as data URLs directly in the `chat_messages` collection. A single image can add 500KB–2MB to a document.

**Impact**: MongoDB documents grow unbounded. Queries on chat become slow. The 16MB BSON document limit can be hit. No CDN caching of assets.

**Fix**: Store files in GridFS (MongoDB's built-in file storage) or an external object store (S3-compatible). Store a reference URL in the message.

---

## KPI Gaps — What's Missing

### Missing Stage Timestamps (fields exist, not all stamped)

| KPI Field | Status |
|---|---|
| `noc_assigned_at` | ✅ Stamped on assignment |
| `sim1_activation_started_at` | ✅ Stamped |
| `sim1_activation_done_at` | ✅ Stamped |
| `sim2_activation_started_at` | ✅ Stamped |
| `sim2_activation_done_at` | ✅ Stamped |
| `ztp_config_verified_at` | ✅ Stamped |
| `ztp_started_at` | ✅ Stamped |
| `ztp_done_at` | ✅ Stamped |
| `ready_for_coordination_at` | ✅ Stamped |
| `hso_submitted_at` | ✅ First submission only — correct |
| `hso_approved_at` | ✅ Stamped |
| `installation_complete_at` | ✅ Stamped |

The core timestamps are all correctly implemented. What's missing is derived or behavioral KPIs:

---

### Missing KPIs by Category

#### Accountability (who is causing delays)

- **Assignment acceptance time by NS**: Time between tracker appearing in NOC queue and NS clicking "Assign to Me". Currently only `queue_wait_minutes` (created → assigned) exists. Need: `created_at → noc_assigned_at` per NS user (already available but not exposed per-operator in analytics).
- **NS idle time on tracker**: Time between assignment and first action (e.g., SIM1 start). Tells you if NS picked it up and sat on it.
  - Formula: `sim1_activation_started_at - noc_assigned_at`
- **FE coordination response time**: Time from `ready_for_coordination_at` to `hso_submitted_at`. After the chat unlocks, how long does the FE take to submit HSO?
  - Formula: `hso_submitted_at - ready_for_coordination_at`
- **HSO rejection → re-submission time**: When HSO is rejected, how long does FE take to correct and re-submit?
  - Source: `hso.attempts[]` array — `attempts[n].submitted_at - attempts[n-1].timestamp` (where n-1 was a rejection)
- **NS HSO review time**: Time from `hso_submitted_at` to `hso_approved_at` or `hso_rejected_at`. Currently `hso_review_minutes` exists but measures first-submission-to-approval only.

#### Quality (what's failing and why)

- **SIM failure reason breakdown**: Aggregate `sim.sim1.failure_reason` / `sim.sim2.failure_reason` by reason string across all trackers. Identifies systemic SIM failure patterns.
- **ZTP failure reason breakdown**: Aggregate `ztp.failure_reason` and `ztp.root_cause_of_initial_failure` across trackers.
- **HSO rejection reason breakdown**: Aggregate `hso.attempts[*].reason` for rejected attempts. Tells you what documentation deficiencies are most common.
- **Multi-attempt rate per NS**: Which NS operators are causing SIM/ZTP retries at a higher rate?
- **ZTP performer impact**: Does NS-performed ZTP take longer or fail more than FE-performed ZTP? (The split count exists; duration and failure rate comparison does not.)

#### Throughput

- **Tracker status funnel**: How many trackers are stuck at each status right now? A live count per-status (not just completed vs in-progress). This exists in `/api/analytics/status-distribution` — but it's not shown as a live KPI card.
- **Daily throughput per NS**: Completed trackers per NS per day. `/api/analytics/noc/user/<id>/day/<date>` exists but is single-day, single-user. Need a multi-day comparison view.
- **Unassigned queue depth over time**: How long is the unassigned queue growing day-over-day? Currently only a snapshot count.

#### SLA / Alerting (not yet built)

- **SLA breach flags**: Define target times per stage (e.g., "queue wait > 60 min = breach"). Flag trackers breaching SLA.
- **Stale tracker detection**: Trackers with no event activity in N hours while not complete.
- **Live NOC workload balance**: How many active trackers each NS has right now.

---

## Improvements Needed

### Real-Time

1. **Add reconnect-room-rejoin logic** to all templates (`socket.on('connect', rejoinRooms)`).

2. **Pass `user_id` in `join_dashboard` emit** so `broadcast_to_user()` works from dashboard pages.

3. **Replace full list reload with targeted dashboard card updates**. The `dashboard_update` payload has enough data (`tracker_id`, `event_type`, `status`) to update a single card without refetching the list.

4. **Consolidate Socket.IO update path**: Choose one: either `renderAll(data.tracker)` (full re-render with existing data) or targeted DOM updates. Currently the flow is ambiguous between `realtime_handler.js` and template-local handlers. Recommendation: delete `realtime_handler.js`, formalize `renderAll(trackerData)` as the contract in both FE and NOC detail pages.

5. **Add connection status indicator**: A small persistent UI element (e.g., a dot in the header) that shows Socket.IO connection state: connected / reconnecting / disconnected. Critical for field use where network is unreliable.

6. **Analytics dashboard Socket.IO**: Connect the analytics dashboard to receive `tracker_update` and `dashboard_update` events so KPI counts update live without manual refresh.

### KPI / Analytics

7. **Add per-stage accountability fields to KPI API**: Expose `ns_idle_time_minutes` (assignment → first SIM start), `fe_coord_response_minutes` (ready_for_coord → HSO submitted), and `hso_rejection_resubmit_minutes` (from attempts array).

8. **Add failure reason aggregation endpoints**:
   - `GET /api/analytics/failure-reasons` — breakdown of SIM/ZTP/HSO failure reasons
   - Powers a "failure pattern" chart in analytics dashboard

9. **Per-operator KPI table**: A ranked table of NS operators by: avg completion time, SIM failure rate, ZTP failure rate, HSO rejection rate, trackers handled. Makes accountability visible.

10. **Switch analytics aggregation to MongoDB pipeline**: Replace Python-side iteration with `$group`, `$avg`, `$sum` pipelines. Necessary for performance at scale.

11. **SLA target config**: Add target thresholds per stage (configurable, not hardcoded). Surface breach counts in KPI cards with visual alerts.

12. **Status funnel live card**: A live count of trackers by status on the analytics dashboard, updated via Socket.IO.

### Code Quality / Production

13. **`debug=True` → environment-gated** — immediate fix before production use.

14. **Move file uploads out of MongoDB documents** — GridFS or external storage for chat attachments.

15. **Add `actor_name` to `make_event()`** — events currently store `actor` (user_id) and `actor_role` but not `actor_name`. Analytics and the event timeline have to do a user lookup or rely on the stored `actor_role` to display a human name. Store name at write time to avoid lookup overhead.

16. **Clarify `ns_processing_minutes` naming** — it's `assigned_at → ready_for_coordination_at` (total NS handling time including SIM + ZTP). Rename to `total_ns_handling_minutes` and expose a separate `post_assignment_idle_minutes` (assignment → SIM1 start) to surface genuine idle time.

---

## Priority Order

| Priority | Item | Impact |
|---|---|---|
| P1 | Fix `user_id` in `join_dashboard` | Notifications work |
| P1 | Add Socket.IO reconnect-rejoin | Real-time doesn't silently break |
| P1 | Gate `debug=True` with env var | Production safety |
| P2 | Targeted dashboard card updates | No full list flicker on every event |
| P2 | Connection status indicator | Field usability on mobile |
| P2 | Consolidate to single Socket.IO update path | Code clarity |
| P2 | Expose `ns_idle_time`, `fe_coord_response` KPIs | Accountability metrics |
| P3 | Failure reason aggregation endpoints | Quality analysis |
| P3 | Per-operator KPI table | Operator-level accountability |
| P3 | Analytics live updates via Socket.IO | Live dashboard |
| P3 | MongoDB aggregation pipeline for analytics | Performance at scale |
| P4 | Move chat files to GridFS | Storage scalability |
| P4 | SLA threshold config + breach flagging | Operational alerts |
