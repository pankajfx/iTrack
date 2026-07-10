"""Android app API layer — mobile-only endpoints under /api/android.

Registered from app.py via:
    from android_backend import register_android_api
    register_android_api(app, mongo)

See PROJECT_GUIDE.md ("Android App") and android/docs/ARCHITECTURE.md.
"""
from android_backend.routes import register_android_api

__all__ = ['register_android_api']
