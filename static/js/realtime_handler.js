/**
 * Real-Time Update Handler
 * Handles Socket.IO-first updates with API fallback
 */

// Initialize global state
if (typeof window.RealtimeHandler === 'undefined') {
    window.RealtimeHandler = {
        lastUpdateSource: 'initial',
        socketUpdateReceived: false,
        updateInProgress: false
    };
}

/**
 * Smart tracker update from Socket.IO data
 */
function updateTrackerFromSocket(trackerData) {
    console.log('[Socket.IO] Updating tracker from Socket.IO data');
    window.RealtimeHandler.lastUpdateSource = 'socket';
    window.RealtimeHandler.socketUpdateReceived = true;
    
    // Update all UI components with new data
    updateTrackerUI(trackerData);
}

/**
 * Unified UI update function - updates all tracker components
 */
function updateTrackerUI(tracker) {
    if (!tracker) {
        console.warn('[UI] No tracker data provided');
        return;
    }
    
    console.log('[UI] Updating tracker UI from', window.RealtimeHandler.lastUpdateSource);
    
    // Update each component
    updateStatusBadge(tracker.status);
    updateTrackerMetadata(tracker);
    updateSIMStatus(tracker.sim);
    updateZTPStatus(tracker.ztp);
    updateHSOStatus(tracker.hso);
    updateEventTimeline(tracker.events);
    updateAssignmentInfo(tracker);
    
    console.log('[UI] Tracker UI updated successfully');
}

/**
 * Update status badge
 */
function updateStatusBadge(status) {
    const badge = document.getElementById('status-badge');
    if (!badge) return;
    
    const statusConfig = {
        'waiting_noc_assignment': { text: 'Waiting Assignment', class: 'bg-yellow-500' },
        'noc_working': { text: 'NOC Working', class: 'bg-blue-500' },
        'sim_activation': { text: 'SIM Activation', class: 'bg-blue-500' },
        'ztp_in_progress': { text: 'ZTP In Progress', class: 'bg-purple-500' },
        'ready_for_coordination': { text: 'Ready for Coordination', class: 'bg-green-500' },
        'fe_requested_ztp': { text: 'FE Requested ZTP', class: 'bg-orange-500' },
        'ztp_pull_requested_from_noc': { text: 'ZTP Pull Requested', class: 'bg-orange-500' },
        'hso_submitted': { text: 'HSO Submitted', class: 'bg-orange-500' },
        'hso_rejected': { text: 'HSO Rejected', class: 'bg-red-500' },
        'installation_complete': { text: 'Complete', class: 'bg-green-600' }
    };
    
    const config = statusConfig[status] || { text: status, class: 'bg-gray-500' };
    badge.textContent = config.text;
    badge.className = `px-3 py-1 rounded-full text-white text-sm font-medium ${config.class}`;
}

/**
 * Update tracker metadata (FE, NOC, customer info)
 */
function updateTrackerMetadata(tracker) {
    // FE info
    const feNameEl = document.getElementById('fe-name');
    if (feNameEl && tracker.fe) {
        feNameEl.textContent = tracker.fe.name || 'N/A';
    }
    
    // NOC assignee
    const nocNameEl = document.getElementById('noc-assignee');
    if (nocNameEl) {
        nocNameEl.textContent = tracker.noc_name || 'Unassigned';
    }
    
    // Customer info
    const customerEl = document.getElementById('customer-name');
    if (customerEl && tracker.customer) {
        customerEl.textContent = tracker.customer.name || 'N/A';
    }
    
    // SDWAN ID
    const sdwanEl = document.getElementById('sdwan-id');
    if (sdwanEl) {
        sdwanEl.textContent = tracker.sdwan_id || 'N/A';
    }
    
    // Tracker ID
    const trackerIdEl = document.getElementById('tracker-id');
    if (trackerIdEl) {
        trackerIdEl.textContent = tracker.tracker_id || 'N/A';
    }
}

/**
 * Update SIM status
 */
function updateSIMStatus(sim) {
    if (!sim) return;
    
    ['sim1', 'sim2'].forEach(simKey => {
        const simData = sim[simKey];
        if (!simData) return;
        
        // Status text
        const statusEl = document.getElementById(`${simKey}-status`);
        if (statusEl) {
            const status = simData.status || 'pending';
            statusEl.textContent = status.charAt(0).toUpperCase() + status.slice(1);
            statusEl.className = `font-medium ${getStatusColorClass(status)}`;
        }
        
        // Activate button
        const buttonEl = document.getElementById(`${simKey}-activate-btn`);
        if (buttonEl) {
            buttonEl.disabled = simData.status === 'activated';
            if (simData.status === 'activated') {
                buttonEl.classList.add('opacity-50', 'cursor-not-allowed');
            } else {
                buttonEl.classList.remove('opacity-50', 'cursor-not-allowed');
            }
        }
        
        // Status icon
        const iconEl = document.getElementById(`${simKey}-status-icon`);
        if (iconEl) {
            if (simData.status === 'activated') {
                iconEl.innerHTML = '<span class="material-symbols-outlined text-green-600">check_circle</span>';
            } else if (simData.status === 'failed') {
                iconEl.innerHTML = '<span class="material-symbols-outlined text-red-600">error</span>';
            } else {
                iconEl.innerHTML = '<span class="material-symbols-outlined text-gray-400">pending</span>';
            }
        }
    });
}

/**
 * Update ZTP status
 */
function updateZTPStatus(ztp) {
    if (!ztp) return;
    
    // Config status
    const configStatusEl = document.getElementById('ztp-config-status');
    if (configStatusEl) {
        const status = ztp.config_status || 'pending';
        configStatusEl.textContent = status.replace('_', ' ').replace(/\b\w/g, l => l.toUpperCase());
        configStatusEl.className = `font-medium ${getStatusColorClass(status)}`;
    }
    
    // Execution status
    const execStatusEl = document.getElementById('ztp-exec-status');
    if (execStatusEl) {
        const status = ztp.status || 'pending';
        execStatusEl.textContent = status.charAt(0).toUpperCase() + status.slice(1);
        execStatusEl.className = `font-medium ${getStatusColorClass(status)}`;
    }
    
    // Start button (FE)
    const startBtnEl = document.getElementById('ztp-start-btn');
    if (startBtnEl) {
        const canStart = ztp.config_status === 'config_verified' && ztp.status === 'pending';
        startBtnEl.disabled = !canStart;
        if (!canStart) {
            startBtnEl.classList.add('opacity-50', 'cursor-not-allowed');
        } else {
            startBtnEl.classList.remove('opacity-50', 'cursor-not-allowed');
        }
    }
    
    // Complete button (FE)
    const completeBtnEl = document.getElementById('ztp-complete-btn');
    if (completeBtnEl) {
        const canComplete = ztp.status === 'initiated' && ztp.performed_by === 'FE';
        completeBtnEl.disabled = !canComplete;
        if (!canComplete) {
            completeBtnEl.classList.add('opacity-50', 'cursor-not-allowed');
        } else {
            completeBtnEl.classList.remove('opacity-50', 'cursor-not-allowed');
        }
    }
    
    // Verify button (NOC)
    const verifyBtnEl = document.getElementById('ztp-verify-btn');
    if (verifyBtnEl) {
        const canVerify = ztp.config_status === 'pending';
        verifyBtnEl.disabled = !canVerify;
    }
    
    // Initiate button (NOC)
    const initiateBtnEl = document.getElementById('ztp-initiate-btn');
    if (initiateBtnEl) {
        const canInitiate = ztp.config_status === 'config_verified' && ztp.status === 'pending';
        initiateBtnEl.disabled = !canInitiate;
    }
}

/**
 * Update HSO status
 */
function updateHSOStatus(hso) {
    if (!hso) return;
    
    // Status text
    const statusEl = document.getElementById('hso-status');
    if (statusEl) {
        const status = hso.status || 'pending';
        statusEl.textContent = status.replace('_', ' ').replace(/\b\w/g, l => l.toUpperCase());
        statusEl.className = `font-medium ${getStatusColorClass(status)}`;
    }
    
    // Submit button (FE)
    const submitBtnEl = document.getElementById('hso-submit-btn');
    if (submitBtnEl) {
        const canSubmit = hso.status === 'pending' || hso.status === 'rejected';
        submitBtnEl.disabled = !canSubmit;
        if (!canSubmit) {
            submitBtnEl.classList.add('opacity-50', 'cursor-not-allowed');
        } else {
            submitBtnEl.classList.remove('opacity-50', 'cursor-not-allowed');
        }
    }
    
    // Approve/Reject buttons (NOC)
    const approveBtnEl = document.getElementById('hso-approve-btn');
    const rejectBtnEl = document.getElementById('hso-reject-btn');
    if (approveBtnEl && rejectBtnEl) {
        const canApprove = hso.status === 'submitted';
        approveBtnEl.disabled = !canApprove;
        rejectBtnEl.disabled = !canApprove;
        
        if (!canApprove) {
            approveBtnEl.classList.add('opacity-50', 'cursor-not-allowed');
            rejectBtnEl.classList.add('opacity-50', 'cursor-not-allowed');
        } else {
            approveBtnEl.classList.remove('opacity-50', 'cursor-not-allowed');
            rejectBtnEl.classList.remove('opacity-50', 'cursor-not-allowed');
        }
    }
    
    // Rejection reason
    if (hso.status === 'rejected' && hso.rejection_reason) {
        const reasonEl = document.getElementById('hso-rejection-reason');
        if (reasonEl) {
            reasonEl.textContent = hso.rejection_reason;
            reasonEl.classList.remove('hidden');
        }
    }
}

/**
 * Update event timeline
 */
function updateEventTimeline(events) {
    if (!events || !Array.isArray(events)) return;
    
    const timelineEl = document.getElementById('event-timeline');
    if (!timelineEl) return;
    
    // Only update if event count changed (avoid unnecessary redraws)
    const currentCount = timelineEl.children.length;
    if (currentCount === events.length) return;
    
    // Rebuild timeline
    timelineEl.innerHTML = events.map(event => `
        <div class="flex gap-4 py-3 border-b border-gray-200 last:border-0">
            <div class="flex-shrink-0 w-32 text-sm text-gray-500">
                ${formatTimestamp(event.timestamp)}
            </div>
            <div class="flex-1">
                <div class="font-medium text-gray-900">${formatStage(event.stage)}</div>
                <div class="text-sm text-gray-600">${event.actor_name || 'System'}</div>
                ${event.remarks ? `<div class="text-sm text-gray-500 mt-1">${event.remarks}</div>` : ''}
            </div>
        </div>
    `).reverse().join('');
}

/**
 * Update assignment info
 */
function updateAssignmentInfo(tracker) {
    // NOC assignee section
    const assigneeSection = document.getElementById('noc-assignee-section');
    if (assigneeSection) {
        if (tracker.noc_assignee) {
            assigneeSection.classList.remove('hidden');
            const assigneeNameEl = document.getElementById('noc-assignee-name');
            if (assigneeNameEl) {
                assigneeNameEl.textContent = tracker.noc_name || 'Unknown';
            }
        } else {
            assigneeSection.classList.add('hidden');
        }
    }
    
    // Assign button
    const assignBtnEl = document.getElementById('assign-to-me-btn');
    if (assignBtnEl) {
        assignBtnEl.disabled = !!tracker.noc_assignee;
        if (tracker.noc_assignee) {
            assignBtnEl.classList.add('opacity-50', 'cursor-not-allowed');
        } else {
            assignBtnEl.classList.remove('opacity-50', 'cursor-not-allowed');
        }
    }
}

/**
 * Helper: Get status color class
 */
function getStatusColorClass(status) {
    const colorMap = {
        'pending': 'text-gray-500',
        'activated': 'text-green-600',
        'failed': 'text-red-600',
        'config_verified': 'text-green-600',
        'config_failed': 'text-red-600',
        'initiated': 'text-blue-600',
        'completed': 'text-green-600',
        'submitted': 'text-orange-600',
        'approved': 'text-green-600',
        'rejected': 'text-red-600'
    };
    return colorMap[status] || 'text-gray-500';
}

/**
 * Helper: Format timestamp to IST
 */
function formatTimestamp(timestamp) {
    if (!timestamp) return 'N/A';
    try {
        const date = new Date(timestamp);
        return date.toLocaleString('en-IN', { 
            timeZone: 'Asia/Kolkata',
            year: 'numeric',
            month: 'short',
            day: 'numeric',
            hour: '2-digit',
            minute: '2-digit'
        });
    } catch (e) {
        return timestamp;
    }
}

/**
 * Helper: Format stage name
 */
function formatStage(stage) {
    if (!stage) return 'Unknown';
    return stage.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
}

/**
 * Enhanced Socket.IO handler for tracker updates
 */
function handleTrackerUpdate(data) {
    const trackerId = window.currentTrackerId || data.tracker_id;
    
    if (data.tracker_id !== trackerId) {
        return; // Not for this tracker
    }
    
    console.log('[Socket.IO] Tracker update received:', data.event_type);
    
    const config = window.REALTIME_CONFIG || { mode: 'hybrid' };
    
    // Check if complete tracker data is available
    if (data.tracker && config.mode !== 'api') {
        // Socket.IO-first: Update directly from Socket.IO data
        updateTrackerFromSocket(data.tracker);
    } else if (config.mode === 'hybrid') {
        // Hybrid mode: Try Socket.IO, fallback to API
        if (data.tracker) {
            updateTrackerFromSocket(data.tracker);
        } else {
            console.log('[Socket.IO] No complete data, falling back to API');
            if (typeof loadTracker === 'function') {
                loadTracker();
            }
        }
    } else {
        // API-only mode: Always use API
        if (typeof loadTracker === 'function') {
            loadTracker();
        }
    }
}

// Export for use in other scripts
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        updateTrackerFromSocket,
        updateTrackerUI,
        handleTrackerUpdate
    };
}
