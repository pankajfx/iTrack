from pymongo import MongoClient
from datetime import datetime, timezone

# Connect to MongoDB
client = MongoClient('mongodb://localhost:27017/')
db = client['sdwan_tracker']

# Create collections
collections = ['trackers', 'noc_users', 'notifications', 'audit_logs', 'predefined_reasons', 'chat_messages']

for collection in collections:
    if collection not in db.list_collection_names():
        db.create_collection(collection)
        print(f"Created collection: {collection}")

# Create indexes
db.trackers.create_index('sdwan_id', unique=True)
db.trackers.create_index('tracker_id')
db.trackers.create_index('noc_assignee')
db.trackers.create_index('status')
db.trackers.create_index('created_at')

db.noc_users.create_index('username', unique=True)

db.chat_messages.create_index('tracker_id')
db.chat_messages.create_index('timestamp')
db.chat_messages.create_index([('tracker_id', 1), ('timestamp', 1)])

print("Indexes created successfully")

# Insert predefined reasons
predefined_reasons = [
    {
        'category': 'sim_activation_failure',
        'reasons': [
            'Incorrect SIM Number',
            'Incorrect SIM Provider',
            'Provider Portal Issue',
            'Network Connectivity Issue',
            'SIM Not Registered',
            'Other'
        ]
    },
    {
        'category': 'ztp_failure',
        'reasons': [
            'Weak Signal',
            'Booster Issue',
            'Incorrect Firmware Info',
            'Configuration Error',
            'Network Timeout',
            'Hardware Issue',
            'Other'
        ]
    },
    {
        'category': 'hso_incomplete',
        'reasons': [
            'Delay due to approval for Single SIM',
            'Delay due to approval for VSAT Only installation',
            'Customer Not Available',
            'Documentation Pending',
            'Technical Issue',
            'Other'
        ]
    },
    {
        'category': 'delay_tags',
        'reasons': [
            'Waiting for Provider Response',
            'Hardware Issue',
            'Site Access Delay',
            'Customer Coordination Delay',
            'Weather Conditions',
            'Power Outage',
            'Other'
        ]
    }
]

for reason_set in predefined_reasons:
    db.predefined_reasons.update_one(
        {'category': reason_set['category']},
        {'$set': reason_set},
        upsert=True
    )
    print(f"Created/Updated predefined reasons for: {reason_set['category']}")

print("\nDatabase initialization completed successfully!")
