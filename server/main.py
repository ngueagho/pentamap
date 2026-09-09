"""
Backend Pentamap — stockage des cartes (chemins extérieurs GPS + ancres
intérieures) et des métadonnées d'ancres Cloud pour la relocalisation
indoor.

Portée volontairement réduite : ce backend NE stocke PAS les données
visuelles des ancres AR elles-mêmes — ça, c'est le rôle du service Google
ARCore Cloud Anchor (appelé directement par le téléphone via
`ARAnchorManager.uploadAnchor()`/`.downloadAnchor()`, qui retournent un
`cloudAnchorId`). Ce backend stocke juste :
  - les graphes de carte complets (nœuds + arêtes), pour remplacer le
    partage par presse-papiers entre appareils ;
  - la correspondance "quel cloudAnchorId appartient à quel nœud de quelle
    carte, à peu près où" — pour permettre une recherche par proximité GPS
    avant de tenter un downloadAnchor.

⚠️ Un projet Google Cloud avec l'API ARCore Cloud Anchor activée (et une clé
API dans l'app) reste nécessaire pour que `uploadAnchor`/`downloadAnchor`
fonctionnent, quel que soit le backend de métadonnées choisi — ce n'est pas
quelque chose que ce serveur peut remplacer.

Lancer en local :
    cd server
    .venv/bin/uvicorn main:app --reload --host 0.0.0.0 --port 8420

Stockage : SQLite (fichier `pentamap.db` à côté de ce script) — suffisant
pour un usage petite équipe/prototype ; à remplacer par Postgres si besoin
de montée en charge plus tard.
"""

import json
import math
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

DB_PATH = Path(__file__).parent / "pentamap.db"

app = FastAPI(title="Pentamap Backend", version="0.1.0")


# --------------------------------------------------------------------------
# Base de données
# --------------------------------------------------------------------------

@contextmanager
def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db():
    with get_db() as db:
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS graphs (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                graph_json TEXT NOT NULL,
                node_count INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS anchors (
                cloud_anchor_id TEXT PRIMARY KEY,
                graph_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY (graph_id) REFERENCES graphs (id)
            )
            """
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS custom_pois (
                id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                color TEXT,
                created_at REAL NOT NULL
            )
            """
        )


@app.on_event("startup")
def on_startup():
    init_db()


# --------------------------------------------------------------------------
# Schémas
# --------------------------------------------------------------------------

class GraphIn(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)
    # Structure libre : on ne valide pas le détail nœuds/arêtes ici, c'est
    # le même format que MapGraph.toJson() côté Flutter — ce backend le
    # traite comme un blob opaque à stocker/restituer tel quel.
    nodes: list[dict]
    edges: list[dict]


class GraphSummary(BaseModel):
    id: str
    name: str
    node_count: int
    created_at: float
    updated_at: float


class GraphOut(GraphSummary):
    nodes: list[dict]
    edges: list[dict]


class AnchorIn(BaseModel):
    cloud_anchor_id: str = Field(..., min_length=1)
    graph_id: str
    node_id: str
    latitude: float
    longitude: float


class AnchorOut(AnchorIn):
    created_at: float
    distance_meters: Optional[float] = None


class GeoJsonImport(BaseModel):
    # Un FeatureCollection GeoJSON brut — le parsing (extraction des
    # géométries Point, du nom et de la couleur depuis les properties) se
    # fait ici, côté serveur. L'app cliente n'a qu'à afficher le résultat
    # (GET /pois) — elle ne parse jamais de fichier elle-même.
    geojson: dict


class CustomPoiOut(BaseModel):
    id: str
    label: str
    latitude: float
    longitude: float
    color: Optional[str] = None
    created_at: float


# --------------------------------------------------------------------------
# Graphes de carte
# --------------------------------------------------------------------------

@app.post("/graphs", response_model=GraphSummary)
def create_graph(graph: GraphIn):
    graph_id = str(uuid.uuid4())
    now = time.time()
    with get_db() as db:
        db.execute(
            """
            INSERT INTO graphs (id, name, graph_json, node_count, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                graph_id,
                graph.name,
                json.dumps({"nodes": graph.nodes, "edges": graph.edges}),
                len(graph.nodes),
                now,
                now,
            ),
        )
    return GraphSummary(
        id=graph_id, name=graph.name, node_count=len(graph.nodes),
        created_at=now, updated_at=now,
    )


@app.put("/graphs/{graph_id}", response_model=GraphSummary)
def update_graph(graph_id: str, graph: GraphIn):
    now = time.time()
    with get_db() as db:
        cur = db.execute(
            """
            UPDATE graphs
            SET name = ?, graph_json = ?, node_count = ?, updated_at = ?
            WHERE id = ?
            """,
            (
                graph.name,
                json.dumps({"nodes": graph.nodes, "edges": graph.edges}),
                len(graph.nodes),
                now,
                graph_id,
            ),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Graphe introuvable")
        row = db.execute(
            "SELECT created_at FROM graphs WHERE id = ?", (graph_id,)
        ).fetchone()
    return GraphSummary(
        id=graph_id, name=graph.name, node_count=len(graph.nodes),
        created_at=row["created_at"], updated_at=now,
    )


@app.get("/graphs", response_model=list[GraphSummary])
def list_graphs():
    with get_db() as db:
        rows = db.execute(
            "SELECT id, name, node_count, created_at, updated_at "
            "FROM graphs ORDER BY updated_at DESC"
        ).fetchall()
    return [GraphSummary(**dict(row)) for row in rows]


@app.get("/graphs/{graph_id}", response_model=GraphOut)
def get_graph(graph_id: str):
    with get_db() as db:
        row = db.execute(
            "SELECT * FROM graphs WHERE id = ?", (graph_id,)
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Graphe introuvable")
    payload = json.loads(row["graph_json"])
    return GraphOut(
        id=row["id"],
        name=row["name"],
        node_count=row["node_count"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
        nodes=payload["nodes"],
        edges=payload["edges"],
    )


@app.delete("/graphs/{graph_id}", status_code=204)
def delete_graph(graph_id: str):
    with get_db() as db:
        cur = db.execute("DELETE FROM graphs WHERE id = ?", (graph_id,))
        db.execute("DELETE FROM anchors WHERE graph_id = ?", (graph_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Graphe introuvable")


# --------------------------------------------------------------------------
# Métadonnées d'ancres Cloud (indoor)
# --------------------------------------------------------------------------

@app.post("/anchors", response_model=AnchorOut)
def register_anchor(anchor: AnchorIn):
    now = time.time()
    with get_db() as db:
        db.execute(
            """
            INSERT OR REPLACE INTO anchors
                (cloud_anchor_id, graph_id, node_id, latitude, longitude, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                anchor.cloud_anchor_id,
                anchor.graph_id,
                anchor.node_id,
                anchor.latitude,
                anchor.longitude,
                now,
            ),
        )
    return AnchorOut(**anchor.model_dump(), created_at=now)


@app.get("/anchors/nearby", response_model=list[AnchorOut])
def anchors_nearby(lat: float, lon: float, radius_m: float = 100.0):
    """Ancres Cloud à moins de `radius_m` mètres de (lat, lon).

    Filtrage naïf en Python (distance de Haversine) — largement suffisant
    pour un volume d'ancres de prototype/petite carte ; à remplacer par une
    extension géospatiale (PostGIS, SpatiaLite) si le volume grossit.
    """
    with get_db() as db:
        rows = db.execute("SELECT * FROM anchors").fetchall()

    results = []
    for row in rows:
        distance = _haversine_meters(lat, lon, row["latitude"], row["longitude"])
        if distance <= radius_m:
            results.append(
                AnchorOut(
                    cloud_anchor_id=row["cloud_anchor_id"],
                    graph_id=row["graph_id"],
                    node_id=row["node_id"],
                    latitude=row["latitude"],
                    longitude=row["longitude"],
                    created_at=row["created_at"],
                    distance_meters=round(distance, 1),
                )
            )
    results.sort(key=lambda a: a.distance_meters)
    return results


def _haversine_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    earth_radius_m = 6_371_000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return earth_radius_m * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


# --------------------------------------------------------------------------
# Points d'intérêt importés (GeoJSON)
# --------------------------------------------------------------------------
# Import et parsing entièrement côté serveur : l'app cliente ne fait jamais
# de sélection/lecture de fichier ni de parsing GeoJSON — elle se contente
# de GET /pois pour afficher ce que le serveur a déjà traité.

@app.post("/pois/import", response_model=list[CustomPoiOut])
def import_pois(payload: GeoJsonImport):
    features = payload.geojson.get("features")
    if features is None:
        raise HTTPException(
            status_code=400,
            detail="GeoJSON invalide : pas de clé 'features'.",
        )

    imported: list[CustomPoiOut] = []
    now = time.time()
    with get_db() as db:
        for i, feature in enumerate(features):
            geometry = feature.get("geometry") or {}
            if geometry.get("type") != "Point":
                continue  # géométries non ponctuelles ignorées pour l'instant

            coords = geometry["coordinates"]
            longitude, latitude = float(coords[0]), float(coords[1])
            properties = feature.get("properties") or {}
            label = str(properties.get("name") or properties.get("label") or f"Point {i + 1}")
            color = properties.get("color")

            poi_id = str(uuid.uuid4())
            db.execute(
                """
                INSERT INTO custom_pois (id, label, latitude, longitude, color, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (poi_id, label, latitude, longitude, color, now),
            )
            imported.append(CustomPoiOut(
                id=poi_id, label=label, latitude=latitude, longitude=longitude,
                color=color, created_at=now,
            ))

    return imported


@app.get("/pois", response_model=list[CustomPoiOut])
def list_pois():
    with get_db() as db:
        rows = db.execute("SELECT * FROM custom_pois ORDER BY created_at DESC").fetchall()
    return [CustomPoiOut(**dict(row)) for row in rows]


@app.delete("/pois/{poi_id}", status_code=204)
def delete_poi(poi_id: str):
    with get_db() as db:
        cur = db.execute("DELETE FROM custom_pois WHERE id = ?", (poi_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Point introuvable")


@app.get("/health")
def health():
    return {"status": "ok"}
