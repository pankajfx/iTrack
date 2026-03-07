---
inclusion: always
---

# Project Structure

## Root Files

- `app.py`: Main Flask application with all routes and business logic
- `theme_config.py`: Theme definitions for FE and NOC dashboards
- `init_db.py`: Database initialization script (collections, indexes, sample data)
- `Requirements.txt`: Python dependencies
- `package.json`: Node.js dependencies (Tailwind CSS)
- `tailwind.config.js`: Tailwind CSS configuration
- `run.bat` / `run.sh`: Platform-specific startup scripts

## Directory Structure

```
.
├── templates/              # Jinja2 HTML templates
│   ├── base.html          # Base template with common layout
│   ├── login.html         # Login page with role selection
│   ├── fe_dashboard.html  # Field Engineer dashboard (mobile-first)
│   ├── fe_new_installation.html  # New tracker creation form
│   ├── fe_tracker_detail.html    # FE tracker detail view
│   ├── noc_dashboard.html        # NOC dashboard (desktop)
│   ├── noc_tracker_detail.html   # NOC tracker detail view
│   ├── analytics_dashboard_v1.html  # Analytics with drill-down
│   ├── chat_component.html       # Chat UI component
│   ├── ztp_component.html        # ZTP workflow component
│   └── theme_styles.html         # Dynamic theme CSS injection
│
├── static/                # Static assets
│   ├── css/
│   │   ├── input.css      # Tailwind source file
│   │   ├── output.css     # Compiled Tailwind CSS
│   │   └── fonts.css      # Font definitions
│   ├── fonts/             # Custom fonts (Fjalla One, Material Symbols)
│   ├── fontawesome-css/   # Font Awesome CSS files
│   └── webfonts/          # Font Awesome web fonts
│
├── assets/                # Documentation and utility scripts (gitignored)
│   ├── md/                # Archived markdown documentation
│   └── scripts/           # Utility and test scripts
│
├── .kiro/                 # Kiro IDE configuration
│   └── steering/          # AI assistant steering rules
│
└── __pycache__/           # Python bytecode cache
```

## Code Organization

### app.py Structure

The main application file is organized into logical sections:

1. **Configuration & Setup**: Flask app, MongoDB connection, role constants
2. **Helper Functions**: `get_utc_now()`, `serialize_doc()`, `make_event()`, `login_required`, `is_chat_unlocked()`
3. **Page Routes**: Dashboard and detail page routes (`/fe/*`, `/noc/*`, `/analytics/*`)
4. **Login/Logout APIs**: Authentication endpoints (`/api/auth/*`, `/api/login/*`)
5. **Tracker Query APIs**: Fetch tracker data (`/api/trackers/*`)
6. **Tracker Creation**: Create new installation trackers (`POST /api/trackers`)
7. **NOC Operations**: Assign, SIM activation, ZTP, HSO approval (`/api/trackers/<id>/*`)
8. **Chat APIs**: FE-NS messaging (`/api/trackers/<id>/chat/*`)
9. **Analytics APIs**: KPI data and drill-down (`/api/analytics/*`)

### Role Constants

Canonical role strings defined at top of app.py:
- `ROLE_FE`: 'FIELD_ENGINEER'
- `ROLE_FEG`: 'FIELD_ENGINEER_GROUP'
- `ROLE_FS`: 'FIELD_SUPPORT'
- `ROLE_FSG`: 'FIELD_SUPPORT_GROUP'
- `ROLE_NS`: 'NOC'
- `ROLE_NSG`: 'NOC_SUPPORT_GROUP'
- `ROLE_ANALYTICS`: 'ANALYTICS'

Use these constants, never hardcode role strings.

## Template Inheritance

All templates extend `base.html` which provides:
- Common HTML structure
- Material Symbols icon font
- Font Awesome icons
- Tailwind CSS
- Theme injection via `theme_styles.html`

## Naming Conventions

- **Python files**: snake_case (e.g., `init_db.py`, `theme_config.py`)
- **Templates**: snake_case (e.g., `fe_dashboard.html`)
- **CSS classes**: Tailwind utility classes (e.g., `bg-blue-500`, `text-lg`)
- **JavaScript**: camelCase for variables/functions
- **MongoDB fields**: snake_case (e.g., `sdwan_id`, `created_at`)
- **API routes**: kebab-case (e.g., `/api/trackers/all-fe`)

## Key Patterns

- **Event-driven tracking**: All state changes append to `events` array in tracker document
- **Embedded documents**: Tracker contains nested objects (fe, sim, router, ztp, hso) rather than separate collections
- **Session-based auth**: User data stored in Flask session, no JWT tokens
- **UTC timestamps**: All times stored as naive UTC datetime, converted to IST in frontend
- **Role-based visibility**: Queries filter by hierarchy (FE sees own, FEG sees group, FS sees region, FSG sees all)
