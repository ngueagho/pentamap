"""
Backend Pentamap — stockage du graphe de navigation unifié (bâtiments,
points intérieurs/extérieurs, liaisons) et des points d'intérêt.

Modèle central : un `graph` (un "site" — campus, établissement) contient des
`nodes` (pièces, intersections, repères GPS) reliés par des `edges`
(couloirs, chemins, distance en mètres). Un `building` n'est pas une entité
séparée du graphe : c'est juste une étiquette géographique (lat/lon, pour
l'afficher sur la carte extérieure) qui pointe vers un nœud d'entrée du
graphe. Résultat : un même Dijkstra sur `nodes`/`edges` calcule nativement un
trajet qui traverse plusieurs bâtiments (salle → sortie → extérieur → entrée
→ salle), sans notion de "mode" intérieur/extérieur séparé.

Deux façons d'éditer ce graphe, toutes deux via cette même API :
  - granulaire (un point, une liaison, un bâtiment à la fois) — utilisée par
    les interfaces d'administration (web et app) ;
  - en lot (`POST /graphs/{id}/nodes/bulk`) — utilisée par la cartographie
    physique par ancres AR (`MappingRecorderScreen`), qui produit toute une
    chaîne de points d'un coup après un parcours sur site.

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
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

DB_PATH = Path(__file__).parent / "pentamap.db"
ADMIN_DIR = Path(__file__).parent / "admin"

app = FastAPI(title="Pentamap Backend", version="0.2.0")


# --------------------------------------------------------------------------
# Base de données
# --------------------------------------------------------------------------

@contextmanager
def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
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
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS buildings (
                id TEXT PRIMARY KEY,
                graph_id TEXT NOT NULL,
                name TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                entrance_node_id TEXT,
                description TEXT,
                created_at REAL NOT NULL,
                FOREIGN KEY (graph_id) REFERENCES graphs (id) ON DELETE CASCADE
            )
            """
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY,
                graph_id TEXT NOT NULL,
                label TEXT NOT NULL,
                kind TEXT NOT NULL,
                latitude REAL,
                longitude REAL,
                altitude REAL,
                anchor_id TEXT,
                local_x REAL,
                local_y REAL,
                local_z REAL,
                floor INTEGER,
                building_id TEXT,
                created_at REAL NOT NULL,
                FOREIGN KEY (graph_id) REFERENCES graphs (id) ON DELETE CASCADE,
                FOREIGN KEY (building_id) REFERENCES buildings (id) ON DELETE SET NULL
            )
            """
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS edges (
                id TEXT PRIMARY KEY,
                graph_id TEXT NOT NULL,
                from_node_id TEXT NOT NULL,
                to_node_id TEXT NOT NULL,
                distance_meters REAL NOT NULL,
                bidirectional INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                FOREIGN KEY (graph_id) REFERENCES graphs (id) ON DELETE CASCADE,
                FOREIGN KEY (from_node_id) REFERENCES nodes (id) ON DELETE CASCADE,
                FOREIGN KEY (to_node_id) REFERENCES nodes (id) ON DELETE CASCADE
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
        _migrate_legacy_blob_graphs(db)


def _migrate_legacy_blob_graphs(db: sqlite3.Connection) -> None:
    """Reprend d'anciens graphes stockés en JSON opaque (colonne `graph_json`,
    schéma d'avant la normalisation) et les éclate dans `nodes`/`edges`.

    Ne s'applique que si la colonne existe encore (base pas déjà migrée) et
    que le graphe n'a pas déjà des nœuds normalisés (évite les doublons si
    on relance la migration).
    """
    cols = {row["name"] for row in db.execute("PRAGMA table_info(graphs)")}
    if "graph_json" not in cols:
        return
    rows = db.execute("SELECT id, graph_json FROM graphs").fetchall()
    for row in rows:
        already = db.execute(
            "SELECT COUNT(*) c FROM nodes WHERE graph_id = ?", (row["id"],)
        ).fetchone()["c"]
        if already:
            continue
        try:
            payload = json.loads(row["graph_json"])
        except (TypeError, ValueError):
            continue
        now = time.time()
        for n in payload.get("nodes", []):
            db.execute(
                """
                INSERT OR IGNORE INTO nodes
                    (id, graph_id, label, kind, latitude, longitude, altitude,
                     anchor_id, local_x, local_y, local_z, floor, building_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    n["id"], row["id"], n.get("label", n["id"]), n["kind"],
                    n.get("latitude"), n.get("longitude"), n.get("altitude"),
                    n.get("anchorId"), n.get("localX"), n.get("localY"), n.get("localZ"),
                    n.get("floor"), None, now,
                ),
            )
        for e in payload.get("edges", []):
            db.execute(
                """
                INSERT OR IGNORE INTO edges
                    (id, graph_id, from_node_id, to_node_id, distance_meters, bidirectional, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()), row["id"], e["fromNodeId"], e["toNodeId"],
                    e["distanceMeters"], 1 if e.get("bidirectional", True) else 0, now,
                ),
            )


@app.on_event("startup")
def on_startup():
    init_db()


# --------------------------------------------------------------------------
# Schémas
# --------------------------------------------------------------------------

class GraphCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)


class GraphSummary(BaseModel):
    id: str
    name: str
    node_count: int
    created_at: float
    updated_at: float


class NodeIn(BaseModel):
    label: str = Field(..., min_length=1, max_length=200)
    kind: str = Field(..., pattern="^(outdoorGps|indoorAnchor)$")
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    altitude: Optional[float] = None
    anchorId: Optional[str] = None
    localX: Optional[float] = None
    localY: Optional[float] = None
    localZ: Optional[float] = None
    floor: Optional[int] = None
    buildingId: Optional[str] = None


class NodeOut(NodeIn):
    id: str
    graphId: str


class EdgeIn(BaseModel):
    fromNodeId: str
    toNodeId: str
    distanceMeters: float
    bidirectional: bool = True


class EdgeOut(EdgeIn):
    id: str
    graphId: str


class BulkIn(BaseModel):
    # Ids fournis par le client (ex: cartographie AR qui génère déjà des ids
    # locaux) sont conservés tels quels ; sinon le serveur en génère.
    nodes: list[dict]
    edges: list[dict]


class BuildingIn(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)
    latitude: float
    longitude: float
    entranceNodeId: Optional[str] = None
    description: Optional[str] = None


class BuildingOut(BuildingIn):
    id: str
    graphId: str


class GraphOut(GraphSummary):
    nodes: list[NodeOut]
    edges: list[EdgeOut]
    buildings: list[BuildingOut]


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
    geojson: dict


class CustomPoiOut(BaseModel):
    id: str
    label: str
    latitude: float
    longitude: float
    color: Optional[str] = None
    created_at: float


# --------------------------------------------------------------------------
# Helpers de lecture
# --------------------------------------------------------------------------

def _node_row_to_out(row: sqlite3.Row) -> NodeOut:
    return NodeOut(
        id=row["id"], graphId=row["graph_id"], label=row["label"], kind=row["kind"],
        latitude=row["latitude"], longitude=row["longitude"], altitude=row["altitude"],
        anchorId=row["anchor_id"], localX=row["local_x"], localY=row["local_y"],
        localZ=row["local_z"], floor=row["floor"], buildingId=row["building_id"],
    )


def _edge_row_to_out(row: sqlite3.Row) -> EdgeOut:
    return EdgeOut(
        id=row["id"], graphId=row["graph_id"], fromNodeId=row["from_node_id"],
        toNodeId=row["to_node_id"], distanceMeters=row["distance_meters"],
        bidirectional=bool(row["bidirectional"]),
    )


def _building_row_to_out(row: sqlite3.Row) -> BuildingOut:
    return BuildingOut(
        id=row["id"], graphId=row["graph_id"], name=row["name"],
        latitude=row["latitude"], longitude=row["longitude"],
        entranceNodeId=row["entrance_node_id"], description=row["description"],
    )


def _require_graph(db: sqlite3.Connection, graph_id: str) -> sqlite3.Row:
    row = db.execute("SELECT * FROM graphs WHERE id = ?", (graph_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Graphe introuvable")
    return row


def _touch_graph(db: sqlite3.Connection, graph_id: str) -> None:
    db.execute("UPDATE graphs SET updated_at = ? WHERE id = ?", (time.time(), graph_id))


# --------------------------------------------------------------------------
# Graphes (sites)
# --------------------------------------------------------------------------

@app.post("/graphs", response_model=GraphSummary)
def create_graph(graph: GraphCreate):
    graph_id = str(uuid.uuid4())
    now = time.time()
    with get_db() as db:
        db.execute(
            "INSERT INTO graphs (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
            (graph_id, graph.name, now, now),
        )
    return GraphSummary(id=graph_id, name=graph.name, node_count=0, created_at=now, updated_at=now)


@app.get("/graphs", response_model=list[GraphSummary])
def list_graphs():
    with get_db() as db:
        rows = db.execute(
            """
            SELECT g.id, g.name, g.created_at, g.updated_at,
                   (SELECT COUNT(*) FROM nodes n WHERE n.graph_id = g.id) AS node_count
            FROM graphs g ORDER BY g.updated_at DESC
            """
        ).fetchall()
    return [GraphSummary(**dict(row)) for row in rows]


@app.get("/graphs/{graph_id}", response_model=GraphOut)
def get_graph(graph_id: str):
    with get_db() as db:
        g = _require_graph(db, graph_id)
        node_rows = db.execute("SELECT * FROM nodes WHERE graph_id = ?", (graph_id,)).fetchall()
        edge_rows = db.execute("SELECT * FROM edges WHERE graph_id = ?", (graph_id,)).fetchall()
        building_rows = db.execute("SELECT * FROM buildings WHERE graph_id = ?", (graph_id,)).fetchall()
    return GraphOut(
        id=g["id"], name=g["name"], created_at=g["created_at"], updated_at=g["updated_at"],
        node_count=len(node_rows),
        nodes=[_node_row_to_out(r) for r in node_rows],
        edges=[_edge_row_to_out(r) for r in edge_rows],
        buildings=[_building_row_to_out(r) for r in building_rows],
    )


@app.delete("/graphs/{graph_id}", status_code=204)
def delete_graph(graph_id: str):
    with get_db() as db:
        cur = db.execute("DELETE FROM graphs WHERE id = ?", (graph_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Graphe introuvable")
        db.execute("DELETE FROM nodes WHERE graph_id = ?", (graph_id,))
        db.execute("DELETE FROM edges WHERE graph_id = ?", (graph_id,))
        db.execute("DELETE FROM buildings WHERE graph_id = ?", (graph_id,))
        db.execute("DELETE FROM anchors WHERE graph_id = ?", (graph_id,))


# --------------------------------------------------------------------------
# Nœuds — édition granulaire (admin web + admin app)
# --------------------------------------------------------------------------

@app.post("/graphs/{graph_id}/nodes", response_model=NodeOut)
def create_node(graph_id: str, node: NodeIn):
    node_id = str(uuid.uuid4())
    now = time.time()
    with get_db() as db:
        _require_graph(db, graph_id)
        db.execute(
            """
            INSERT INTO nodes (id, graph_id, label, kind, latitude, longitude, altitude,
                                anchor_id, local_x, local_y, local_z, floor, building_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                node_id, graph_id, node.label, node.kind, node.latitude, node.longitude,
                node.altitude, node.anchorId, node.localX, node.localY, node.localZ,
                node.floor, node.buildingId, now,
            ),
        )
        _touch_graph(db, graph_id)
    return NodeOut(id=node_id, graphId=graph_id, **node.model_dump())


@app.put("/graphs/{graph_id}/nodes/{node_id}", response_model=NodeOut)
def update_node(graph_id: str, node_id: str, node: NodeIn):
    with get_db() as db:
        cur = db.execute(
            """
            UPDATE nodes SET label=?, kind=?, latitude=?, longitude=?, altitude=?,
                              anchor_id=?, local_x=?, local_y=?, local_z=?, floor=?, building_id=?
            WHERE id = ? AND graph_id = ?
            """,
            (
                node.label, node.kind, node.latitude, node.longitude, node.altitude,
                node.anchorId, node.localX, node.localY, node.localZ, node.floor,
                node.buildingId, node_id, graph_id,
            ),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Nœud introuvable")
        _touch_graph(db, graph_id)
    return NodeOut(id=node_id, graphId=graph_id, **node.model_dump())


@app.delete("/graphs/{graph_id}/nodes/{node_id}", status_code=204)
def delete_node(graph_id: str, node_id: str):
    with get_db() as db:
        cur = db.execute(
            "DELETE FROM nodes WHERE id = ? AND graph_id = ?", (node_id, graph_id)
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Nœud introuvable")
        db.execute(
            "DELETE FROM edges WHERE graph_id = ? AND (from_node_id = ? OR to_node_id = ?)",
            (graph_id, node_id, node_id),
        )
        db.execute(
            "UPDATE buildings SET entrance_node_id = NULL WHERE entrance_node_id = ?",
            (node_id,),
        )
        _touch_graph(db, graph_id)


@app.post("/graphs/{graph_id}/nodes/bulk", response_model=GraphOut)
def bulk_add_nodes(graph_id: str, payload: BulkIn):
    """Ajoute (append, ne remplace rien) un lot de nœuds + arêtes d'un coup —
    utilisé par la cartographie physique par ancres AR (`MappingRecorderScreen`)
    après un parcours sur site. Les ids fournis par le client sont conservés
    (nécessaire pour que ses arêtes locales `fromNodeId`/`toNodeId` restent
    cohérentes) ; un id est généré côté serveur seulement s'il manque.
    """
    now = time.time()
    with get_db() as db:
        _require_graph(db, graph_id)
        for n in payload.nodes:
            node_id = n.get("id") or str(uuid.uuid4())
            db.execute(
                """
                INSERT OR REPLACE INTO nodes
                    (id, graph_id, label, kind, latitude, longitude, altitude,
                     anchor_id, local_x, local_y, local_z, floor, building_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    node_id, graph_id, n.get("label", node_id), n["kind"],
                    n.get("latitude"), n.get("longitude"), n.get("altitude"),
                    n.get("anchorId"), n.get("localX"), n.get("localY"), n.get("localZ"),
                    n.get("floor"), n.get("buildingId"), now,
                ),
            )
        for e in payload.edges:
            edge_id = e.get("id") or str(uuid.uuid4())
            db.execute(
                """
                INSERT OR REPLACE INTO edges
                    (id, graph_id, from_node_id, to_node_id, distance_meters, bidirectional, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    edge_id, graph_id, e["fromNodeId"], e["toNodeId"],
                    e["distanceMeters"], 1 if e.get("bidirectional", True) else 0, now,
                ),
            )
        _touch_graph(db, graph_id)
    return get_graph(graph_id)


# --------------------------------------------------------------------------
# Arêtes — édition granulaire
# --------------------------------------------------------------------------

@app.post("/graphs/{graph_id}/edges", response_model=EdgeOut)
def create_edge(graph_id: str, edge: EdgeIn):
    edge_id = str(uuid.uuid4())
    now = time.time()
    with get_db() as db:
        _require_graph(db, graph_id)
        for nid in (edge.fromNodeId, edge.toNodeId):
            if not db.execute(
                "SELECT 1 FROM nodes WHERE id = ? AND graph_id = ?", (nid, graph_id)
            ).fetchone():
                raise HTTPException(status_code=400, detail=f"Nœud inconnu : {nid}")
        db.execute(
            """
            INSERT INTO edges (id, graph_id, from_node_id, to_node_id, distance_meters, bidirectional, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (edge_id, graph_id, edge.fromNodeId, edge.toNodeId, edge.distanceMeters,
             1 if edge.bidirectional else 0, now),
        )
        _touch_graph(db, graph_id)
    return EdgeOut(id=edge_id, graphId=graph_id, **edge.model_dump())


@app.delete("/graphs/{graph_id}/edges/{edge_id}", status_code=204)
def delete_edge(graph_id: str, edge_id: str):
    with get_db() as db:
        cur = db.execute(
            "DELETE FROM edges WHERE id = ? AND graph_id = ?", (edge_id, graph_id)
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Liaison introuvable")
        _touch_graph(db, graph_id)


# --------------------------------------------------------------------------
# Bâtiments — repère géographique (lat/lon) + nœud d'entrée dans le graphe
# --------------------------------------------------------------------------

@app.post("/graphs/{graph_id}/buildings", response_model=BuildingOut)
def create_building(graph_id: str, building: BuildingIn):
    building_id = str(uuid.uuid4())
    now = time.time()
    with get_db() as db:
        _require_graph(db, graph_id)
        db.execute(
            """
            INSERT INTO buildings (id, graph_id, name, latitude, longitude, entrance_node_id, description, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (building_id, graph_id, building.name, building.latitude, building.longitude,
             building.entranceNodeId, building.description, now),
        )
        _touch_graph(db, graph_id)
    return BuildingOut(id=building_id, graphId=graph_id, **building.model_dump())


@app.put("/graphs/{graph_id}/buildings/{building_id}", response_model=BuildingOut)
def update_building(graph_id: str, building_id: str, building: BuildingIn):
    with get_db() as db:
        cur = db.execute(
            """
            UPDATE buildings SET name=?, latitude=?, longitude=?, entrance_node_id=?, description=?
            WHERE id = ? AND graph_id = ?
            """,
            (building.name, building.latitude, building.longitude, building.entranceNodeId,
             building.description, building_id, graph_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Bâtiment introuvable")
        _touch_graph(db, graph_id)
    return BuildingOut(id=building_id, graphId=graph_id, **building.model_dump())


@app.delete("/graphs/{graph_id}/buildings/{building_id}", status_code=204)
def delete_building(graph_id: str, building_id: str):
    with get_db() as db:
        cur = db.execute(
            "DELETE FROM buildings WHERE id = ? AND graph_id = ?", (building_id, graph_id)
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Bâtiment introuvable")
        db.execute("UPDATE nodes SET building_id = NULL WHERE building_id = ?", (building_id,))
        _touch_graph(db, graph_id)


# --------------------------------------------------------------------------
# Métadonnées d'ancres Cloud (indoor) — inchangé
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
            (anchor.cloud_anchor_id, anchor.graph_id, anchor.node_id,
             anchor.latitude, anchor.longitude, now),
        )
    return AnchorOut(**anchor.model_dump(), created_at=now)


@app.get("/anchors/nearby", response_model=list[AnchorOut])
def anchors_nearby(lat: float, lon: float, radius_m: float = 100.0):
    with get_db() as db:
        rows = db.execute("SELECT * FROM anchors").fetchall()
    results = []
    for row in rows:
        distance = _haversine_meters(lat, lon, row["latitude"], row["longitude"])
        if distance <= radius_m:
            results.append(
                AnchorOut(
                    cloud_anchor_id=row["cloud_anchor_id"], graph_id=row["graph_id"],
                    node_id=row["node_id"], latitude=row["latitude"], longitude=row["longitude"],
                    created_at=row["created_at"], distance_meters=round(distance, 1),
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
# Points d'intérêt importés (GeoJSON) — inchangé
# --------------------------------------------------------------------------

@app.post("/pois/import", response_model=list[CustomPoiOut])
def import_pois(payload: GeoJsonImport):
    features = payload.geojson.get("features")
    if features is None:
        raise HTTPException(status_code=400, detail="GeoJSON invalide : pas de clé 'features'.")

    imported: list[CustomPoiOut] = []
    now = time.time()
    with get_db() as db:
        for i, feature in enumerate(features):
            geometry = feature.get("geometry") or {}
            if geometry.get("type") != "Point":
                continue
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


# --------------------------------------------------------------------------
# Dashboard admin (page web statique servie par ce même backend)
# --------------------------------------------------------------------------

if ADMIN_DIR.exists():
    app.mount("/admin", StaticFiles(directory=str(ADMIN_DIR), html=True), name="admin")
