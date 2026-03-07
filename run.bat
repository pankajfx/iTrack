@echo off
echo Starting SD-WAN Installation Tracker...
echo.

REM Check if virtual environment exists
if not exist "venv\" (
    echo Creating virtual environment...
    python -m venv venv
    echo.
)

REM Activate virtual environment
call venv\Scripts\activate

REM Install dependencies
echo Installing dependencies...
pip install -r Requirements.txt
echo.

REM Check if MongoDB is running
echo Checking MongoDB connection...
python -c "from pymongo import MongoClient; client = MongoClient('mongodb://localhost:27017/', serverSelectionTimeoutMS=2000); client.server_info(); print('MongoDB is running!')" 2>nul
if errorlevel 1 (
    echo.
    echo WARNING: MongoDB is not running!
    echo Please start MongoDB before running the application.
    echo.
    pause
    exit /b 1
)

REM Initialize database
echo.
echo Checking and initializing database...
python init_db.py
echo.

REM Run the application
echo Starting Flask application...
echo.
echo Application will be available at: http://localhost:5000
echo.
python app.py
