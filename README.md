# SDWAN Installation Tracker — Production Deployment

This folder contains the **exact, clean file set** required for deployment. It excludes all development artifacts, test scripts, old/redundant templates, and build tooling.

---

## Quick Start

```bash
# Windows
run.bat

# Linux/Mac
chmod +x run.sh && ./run.sh
```

Set environment variables before running:
```bash
MONGO_URI=mongodb://localhost:27017/sdwan_tracker
SECRET_KEY=your-secret-key-here
```

---

## File Structure

```
.production/
├── app.py                          # Main Flask application (all routes + business logic)
├── theme_config.py                 # Role-based theme definitions
├── init_db.py                      # Database initialization (indexes + collections)
├── Requirements.txt                # Python dependencies
├── package.json                    # Node.js deps (Tailwind CSS build only)
├── tailwind.config.js              # Tailwind configuration
├── run.bat                         # Windows startup script
├── run.sh                          # Linux/Mac startup script
├── .gitignore                      # Git ignore rules
│
├── .kiro/steering/                 # AI assistant context (Kiro/Claude)
│   ├── product.md                  # Product overview and workflow
│   ├── structure.md                # Code structure and conventions
│   └── tech.md                     # Technology stack reference
│
├── templates/                      # Jinja2 HTML templates (active only)
│   ├── base.html                   # Base layout: Tailwind, Material Symbols, Socket.IO CDN
│   ├── login.html                  # Login page with role selection
│   ├── theme_styles.html           # Dynamic CSS variable injection per role/theme
│   ├── fe_dashboard.html           # Field Engineer dashboard (mobile-first)
│   ├── fe_new_installation.html    # New tracker creation form
│   ├── fe_tracker_detail.html      # FE tracker detail + ZTP + HSO workflow
│   ├── noc_dashboard.html          # NOC dashboard (desktop-optimized)
│   ├── noc_tracker_detail.html     # NOC tracker detail + SIM + ZTP + HSO approval
│   ├── analytics_dashboard_v1.html # Analytics with drill-down charts
│   └── chat_component.html         # FE-NS coordination chat (included in detail views)
│
└── static/
    ├── css/
    │   ├── output.css              # Compiled Tailwind CSS (production-ready)
    │   ├── input.css               # Tailwind source (only needed to rebuild CSS)
    │   └── fonts.css               # Custom font-face definitions
    ├── fonts/
    │   ├── FjallaOne-Regular.ttf   # Header font (self-hosted)
    │   └── MaterialSymbolsOutlined.woff2  # Icon font (self-hosted, preloaded)
    └── js/
        └── realtime_handler.js     # Socket.IO-first update handler with API fallback
```

---

## What Was Excluded (and Why)

| Excluded | Reason |
|---|---|
| `assets/` | Dev-time scripts and docs (gitignored). One-time-use scripts for DB seeding, icon migration, analytics setup, etc. |
| `node_modules/` | Build dependency only. `output.css` is pre-compiled. |
| `__pycache__/` | Python bytecode cache — auto-regenerated |
| `venv/` | Virtual environment — recreated by run scripts |
| `static/fonts/fontawesome/fontawesome.zip` | Source archive — not served |
| `static/fontawesome-css/` | Font Awesome CSS files — not linked in any template (FA icons emulated via CSS in base.html) |
| `static/webfonts/` | Font Awesome web fonts — unused (see above) |
| `static/js/socketio_client.js` | Not referenced in any template (Socket.IO loaded via CDN in base.html) |
| `templates/debug_time.html` | Debug-only, not used in any route |
| `templates/login.html.backup` | Old backup file |
| `templates/version_check.html` | Debug-only |
| `templates/analytics_dashboard.html` | Superseded by `analytics_dashboard_v1.html` |
| `templates/ztp_component.html` | Not included in any template (ZTP is inline in tracker detail views) |
| `templates/ztp_component_js.html` | Unused extraction file |
| `templates/fe_new_installation_modern.html` | Old/alternative version, not routed |

---

## Key Architecture Notes

- **Socket.IO** is loaded from CDN (`cdn.socket.io/4.7.2`) in `base.html` — no local copy needed
- **Material Symbols** font is self-hosted from `static/fonts/` and preloaded for performance
- **Font Awesome** icons are CSS-emulated (emoji) in `base.html` — the icon font files are NOT needed
- **Tailwind CSS** `output.css` is pre-compiled — `node_modules/` only needed if rebuilding CSS
- **Themes** are injected server-side via `theme_config.py` → `theme_styles.html` per role
- **Real-time**: Socket.IO-first with REST API fallback, controlled by `REALTIME_MODE` env var

---

## Setup for Fresh Deployment

```bash
# 1. Install Python dependencies
pip install -r Requirements.txt

# 2. Set environment variables
export MONGO_URI="mongodb://localhost:27017/sdwan_tracker"
export SECRET_KEY="your-strong-secret-key"

# 3. Initialize database (collections, indexes, sample users)
python init_db.py

# 4. (Optional) Rebuild Tailwind CSS if templates were modified
npm install
npm run build:css

# 5. Run
python app.py
```
