#!/bin/bash

echo "Starting SD-WAN Installation Tracker..."
echo ""

# Check if virtual environment exists
if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
    echo ""
fi

# Activate virtual environment
source venv/bin/activate

# Install dependencies
echo "Installing dependencies..."
pip install -r Requirements.txt
echo ""

# Check if MongoDB is running
echo "Checking MongoDB connection..."
python3 -c "from pymongo import MongoClient; client = MongoClient('mongodb://localhost:27017/', serverSelectionTimeoutMS=2000); client.server_info(); print('MongoDB is running!')" 2>/dev/null
if [ $? -ne 0 ]; then
    echo ""
    echo "WARNING: MongoDB is not running!"
    echo "Please start MongoDB before running the application."
    echo ""
    exit 1
fi

# Initialize database
echo ""
echo "Checking and initializing database..."
python3 init_db.py
echo ""

# Run the application
echo "Starting Flask application..."
echo ""
echo "Application will be available at: http://localhost:5000"
echo ""
python3 app.py
