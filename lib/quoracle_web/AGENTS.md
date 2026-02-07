# lib/quoracle_web/

## Module Purpose
Phoenix web interface for Quoracle - handles HTTP/WebSocket connections, LiveView UI

## Core Modules
- Endpoint: HTTP server configuration, WebSocket handling
- Router: Request routing, pipelines
- Telemetry: Metrics collection and monitoring
- Gettext: i18n support

## Key Functions
- Endpoint.start_link/1: Starts HTTP server on configured port
- Router pipelines: :browser (HTML), :api (JSON)
- Telemetry.metrics/0: Returns app metrics for LiveDashboard

## Patterns
- Plugs for request pipeline
- LiveView for real-time UI
- Component-based UI architecture
- Gettext backend for translations

## Configuration
- Dev: port 4000, code reloading, live reload
- Test: port 4002, server: false by default
- Prod: via runtime.exs

## Dependencies
- Phoenix 1.7.21
- Phoenix.LiveView 1.1.11
- Cowboy 2.13.0 (HTTP server)
- Tailwind CSS (styling)
- esbuild (JS bundling)