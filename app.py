from flask import Flask, request, jsonify
from pymongo import MongoClient
from urllib.parse import quote_plus
from datetime import datetime
import os

app = Flask(__name__)


def build_mongo_uri():
    """Build the MongoDB connection string.

    MONGODB_URI wins if set (handy for local runs). Otherwise the URI is
    assembled from the parts Kubernetes injects: credentials come from a
    Secret, host/port/db from plain env vars.
    """
    uri = os.environ.get("MONGODB_URI")
    if uri:
        return uri

    username = os.environ.get("MONGO_USERNAME")
    password = os.environ.get("MONGO_PASSWORD")
    host = os.environ.get("MONGO_HOST", "localhost")
    port = os.environ.get("MONGO_PORT", "27017")
    auth_db = os.environ.get("MONGO_AUTH_DB", "flask_db")

    if username and password:
        # quote_plus keeps passwords with @ : / etc. from breaking the URI
        return (
            f"mongodb://{quote_plus(username)}:{quote_plus(password)}"
            f"@{host}:{port}/?authSource={auth_db}"
        )
    return f"mongodb://{host}:{port}/"


# Fail fast (5s) instead of the 30s pymongo default if Mongo is unreachable
client = MongoClient(build_mongo_uri(), serverSelectionTimeoutMS=5000)
db = client[os.environ.get("MONGO_DB_NAME", "flask_db")]
collection = db.data


@app.route('/')
def index():
    return f"Welcome to the Flask app! The current time is: {datetime.now()}"


@app.route('/data', methods=['GET', 'POST'])
def data():
    if request.method == 'POST':
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify({"error": "Request body must be a JSON object"}), 400
        collection.insert_one(payload)
        return jsonify({"status": "Data inserted"}), 201

    documents = list(collection.find({}, {"_id": 0}))
    return jsonify(documents), 200


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
