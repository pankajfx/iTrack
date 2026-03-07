---
inclusion: always
---

# Technology Stack

## Backend

- **Framework**: Flask 3.0.0 (Python web framework)
- **Real-Time**: Flask-SocketIO 5.3.6 with threading async mode (Windows compatible)
- **Database**: MongoDB with PyMongo 4.6.1 and Flask-PyMongo 2.3.0
- **Authentication**: Flask sessions with Werkzeug 3.0.1 password handling
- **Environment**: python-dotenv 1.0.0 for configuration
- **Image Processing**: Pillow 10.2.0
- **Excel**: openpyxl 3.1.2 for analytics export

## Frontend

- **CSS Framework**: Tailwind CSS 3.4.1 (utility-first CSS)
- **Real-Time**: Socket.IO Client 4.7.2 for WebSocket connections
- **Icons**: Material Symbols Outlined (Google) + Font Awesome 7.2.0
- **Charts**: Chart.js 4.4.0 with zoom plugin for analytics
- **Fonts**: Fjalla One (headers), Inter (body text)
- **Templates**: Jinja2 (Flask default)

## Database Schema

MongoDB collections:
- `users`: User accounts with role-based hierarchy
- `trackers`: Installation tracking documents with embedded events
- `chat_messages`: FE-NS coordination messages
- `predefined_reasons`: Dropdown options for failures/delays
- `audit_logs`: System audit trail
- `notifications`: User notifications

Key indexes on `trackers`: sdwan_id (unique), tracker_id, noc_assignee, status, created_at

## Common Commands

### Setup
```bash
# Install Python dependencies
pip install -r Requirements.txt

# Install Node dependencies (Tailwind)
npm install

# Initialize database with indexes and sample data
python init_db.py
```

### Development
```bash
# Build Tailwind CSS (production)
npm run build:css

# Watch Tailwind CSS (development)
npm run watch:css

# Run Flask development server
python app.py
# OR use platform-specific scripts:
run.bat    # Windows
./run.sh   # Linux/Mac
```

### Database Operations
```bash
# Populate test data
python populate_tracker_data.py

# Check users
python check_users.py

# Reset database with fresh users
python reset_db_with_users.py
```

## Configuration

- **MongoDB URI**: Set via `MONGO_URI` environment variable (default: `mongodb://localhost:27017/sdwan_tracker`)
- **Secret Key**: Set via `SECRET_KEY` environment variable (default: dev key)
- **Themes**: Configure in `theme_config.py` (ACTIVE_FE_THEME, ACTIVE_NOC_THEME)
- **Max Upload Size**: 16MB (configured in app.py)

## Time Handling

All timestamps stored as naive UTC datetime in MongoDB. Frontend converts to IST (+5:30) for display. Use `get_utc_now()` helper for consistent UTC timestamps.

## Development Server

Default: `http://localhost:5000`

Instructions
Dont create additional md documents for small changes
Make inserts into a common md document
Move test scripts and other scripts to assets folder
Keep the project strcuture clean with only essential files and folders in root.
Non essential and one time run scripts must move inside the asssets folder.