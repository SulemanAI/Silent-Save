# SilentSave - Hands-On Architecture & Logic Guide

This document outlines the core architectural decisions, logic flows, and professional practices implemented in SilentSave's media handling and auto-linking systems. It serves as a technical defense and explanation for code reviewers and future engineers.

---

## 1. Zero-Touch Media Auto-Linking (SAF + Notifications)

SilentSave uses a "Zero-Touch" matching engine to silently link media files (downloaded in the background by WhatsApp) to their corresponding notification text messages (e.g., "📷 Photo", "🎤 Voice message") without requiring any manual user intervention.

### How it Works (Images, Videos, Voice Notes, etc.)
1. **Notification Intercept:** A notification arrives (e.g., from Basit saying "📷 Photo"). The app logs this into the `messages` database.
2. **File Capture:** WhatsApp auto-downloads the file to device storage. SilentSave's `MediaWatcherService` detects this file creation via Android's Storage Access Framework (SAF) and records the file's timestamp.
3. **Temporal Matching:** `NotificationService` calls `TimestampMatcher`. The matcher scans the database for any WhatsApp media notifications received within a tight ±30-to-60 second window around the file's creation time.
4. **The Link:** If an unambiguous match is found within that exact time window, the system permanently links the high-quality file directly to the sender's message.

### Unblocking Voice Notes
Previously, voice notes (`.opus` or `PTT-` files) were strictly blocked from this zero-touch process because SAF does not provide contact metadata in the filename. This block was **removed** because it was overly restrictive. By removing it, voice notes now pass through the zero-touch pipeline. They are successfully linked using temporal matching just like images and videos, drastically improving the user experience without sacrificing safety.

---

## 2. Handling Collisions: The "Fail-Safe" Professional Practice

Reviewers often ask: *"What if Alice and Bob both send a photo at the exact same millisecond? Will the system link Alice's photo to Bob's chat?"*

SilentSave uses **Fail-Safe Design** (or "Failing Closed") to prevent this. 

### The `requireUnambiguous` Guard
In `TimestampMatcher.dart`, the matching algorithm enforces `requireUnambiguous = true`. If the algorithm detects *more than one* valid notification candidate within the temporal window (e.g., both Alice and Bob sent a picture at 12:00:01), it flags the match as `ambiguous` and **completely aborts the linking process**.

### Why This is an Industry Best Practice
* **Privacy Over Convenience:** Showing Alice's private picture in Bob's chat history is a catastrophic privacy breach (a P0 critical bug). Failing to auto-link the picture is a minor inconvenience. Professional systems prioritize data integrity.
* **Deterministic Behavior:** If an algorithm guesses during a 50/50 split, the system behaves unpredictably. Aborting on ambiguity guarantees 100% predictable, safe behavior.
* **Database Contamination Prevention:** Incorrectly linking a file corrupts the user's local chat database permanently. Failing safely prevents this contamination.

---

## 3. The 5-Tier Media Display Fallback Logic

When rendering messages in the chat interface, SilentSave uses a robust, "Simple Yet Advanced" 5-tier fallback chain. This ensures the app never displays broken UI or raw text labels (like "photo") when something goes wrong.

*Note: Per application requirements, media rendering is strictly isolated to WhatsApp. Non-WhatsApp messages immediately bypass this engine and fall back to standard text.*

### The Fallback Chain
1. **Call Notifications:** Instantly bypassed. Rendered as standard text.
2. **File Exists on Disk:** If a `mediaPath` is recorded and the physical file still exists on the user's device, the app renders the rich media (Image Viewer, Video Player, Audio Player, Document Card).
3. **Unloaded Voice Note, Video & Document:** If the app is unable to load the voice note, video, or document (file was not captured, deleted, or cannot be loaded):
   * **Voice Note:** Rendered directly as text in the bubble (e.g. `🎤 Voice message (0:02)`).
   * **Video:** Rendered directly as text in the bubble (e.g. `🎤 Video (0:05)`).
   * **Document:** Rendered directly as text showing the document name (e.g. `resume.pdf`).
4. **Missing Photos & Photo Placeholders:** Photos with stale paths show the sleek "Photo · No longer available" card, and uncaptured photos show the tap-to-learn-more placeholder.
5. **Plain Text:** The ultimate fallback for standard non-media messages.
