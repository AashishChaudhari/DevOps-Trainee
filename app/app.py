import os
from flask import Flask, jsonify
import psycopg2

app = Flask(__name__)

def get_db_connection():
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "db"),
        database=os.environ.get("DB_NAME", "appdb"),
        user=os.environ.get("DB_USER", "appuser"),
        password=os.environ.get("DB_PASSWORD", "apppass")
    )

@app.route("/")
def home():
    return jsonify(message="Hello from Flask! Reverse proxy is working.")

@app.route("/health")
def health():
    try:
        conn = get_db_connection()
        conn.close()
        return jsonify(status="ok", db="connected")
    except Exception as e:
        return jsonify(status="error", db=str(e)), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
