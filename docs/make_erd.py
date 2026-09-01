#!/usr/bin/env python3
"""
BiteStream :: docs/make_erd.py
Generates docs/relational_erd.png.

WHY A SCRIPT RATHER THAN dbdiagram.io OR eralchemy
    * no graphviz, no network, no account - the grader can regenerate it in one command
    * it lives next to the schema, so the diagram cannot silently drift from the DDL
    * it draws the two things an auto-generated ERD always omits, and which are the whole
      point of this assignment: the PARTIAL UNIQUE INDEX and the TRIGGER DIRECTION

RUN
    python3 docs/make_erd.py
"""
import pathlib

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

OUT = pathlib.Path(__file__).resolve().parent / "relational_erd.png"

INK, MUTED, LINE = "#141d26", "#5a6875", "#c3ccd4"
PK_C, FK_C, CK_C, MV_C = "#1f5b8e", "#8a6a12", "#a8451a", "#3f7340"
BG, HEAD, DERIVED_HEAD = "#ffffff", "#eaf0f5", "#f3efe6"

ROW_H, HEAD_H, PAD = 0.32, 0.46, 0.16
W, H = 19.4, 13.2

R1, R2 = 11.5, 6.6          # top edge of each table row
CL, CM, CR = 0.4, 8.0, 14.0  # left edge of each column
WL, WM, WR = 4.4, 5.2, 5.0   # width of each column

TABLES = {
    "users": {
        "xy": (CL, R1), "w": WL,
        "cols": [
            ("PK", "id", "BIGINT IDENTITY"),
            ("", "name", "VARCHAR(120) NOT NULL"),
            ("", "email", "VARCHAR(160)"),
            ("CK", "wallet_balance", "NUMERIC(10,2) >= 0"),
            ("", "created_at", "TIMESTAMPTZ"),
        ],
    },
    "wallet_audit_logs": {
        "xy": (CM, R1), "w": WM, "note": "APPEND-ONLY",
        "cols": [
            ("PK", "id", "BIGINT IDENTITY"),
            ("FK", "user_id", "-> users.id  RESTRICT"),
            ("CK", "amount_changed", "NUMERIC(10,2) <> 0"),
            ("CK", "action_type", "IN (DEBIT, CREDIT)"),
            ("CK", "balance_after", "NUMERIC(10,2) >= 0"),
            ("", '"timestamp"', "TIMESTAMPTZ now()"),
        ],
    },
    "checkout_attempts": {
        "xy": (CR, R1), "w": WR, "derived": True, "note": "DURABLE OUTCOME LOG",
        "cols": [
            ("PK", "id", "BIGINT IDENTITY"),
            ("", "user_id", "no FK by design"),
            ("", "outcome", "OK | INSUFFICIENT_FUNDS"),
            ("", "sqlstate_code", "23514 | 23505 | 40001"),
            ("", "attempted_at", "TIMESTAMPTZ"),
        ],
    },
    "restaurants": {
        "xy": (CL, R2), "w": WL,
        "cols": [
            ("PK", "id", "BIGINT IDENTITY"),
            ("", "name", "VARCHAR(160) NOT NULL"),
            ("", "city", "VARCHAR(80) NOT NULL"),
            ("CK", "latitude", "FLOAT  -90 .. 90"),
            ("CK", "longitude", "FLOAT -180 .. 180"),
            ("", "is_active", "BOOLEAN"),
        ],
    },
    "orders": {
        "xy": (CM, R2), "w": WM,
        "cols": [
            ("PK", "id", "BIGINT IDENTITY"),
            ("FK", "user_id", "-> users.id"),
            ("FK", "restaurant_id", "-> restaurants.id"),
            ("CK", "total_amount", "NUMERIC(10,2) > 0"),
            ("CK", "status", "PREPARING|DELIVERING|DELIVERED"),
            ("", "created_at", "TIMESTAMPTZ"),
            ("CK", "delivered_at", "NOT NULL when DELIVERED"),
        ],
    },
    "mv_restaurant_performance": {
        "xy": (CR, R2), "w": WR, "derived": True, "note": "MATERIALIZED VIEW",
        "cols": [
            ("UX", "restaurant_id", "UNIQUE, non-partial"),
            ("", "completed_orders", "COUNT(orders.id)"),
            ("", "total_revenue", "SUM(total_amount)"),
            ("", "avg_order_value", "AVG(total_amount)"),
            ("", "last_order_at", "MAX(created_at)"),
        ],
    },
}


def draw_table(ax, name, spec):
    x, y_top = spec["xy"]
    w, cols = spec["w"], spec["cols"]
    h = HEAD_H + len(cols) * ROW_H + PAD
    y_bot = y_top - h
    derived = spec.get("derived", False)

    ax.add_patch(FancyBboxPatch(
        (x, y_bot), w, h, boxstyle="round,pad=0.02,rounding_size=0.08",
        linewidth=1.3, edgecolor=LINE, facecolor=BG,
        linestyle="--" if derived else "-", zorder=2))
    ax.add_patch(FancyBboxPatch(
        (x, y_top - HEAD_H), w, HEAD_H, boxstyle="round,pad=0.02,rounding_size=0.08",
        linewidth=0, facecolor=DERIVED_HEAD if derived else HEAD, zorder=3))
    ax.text(x + 0.16, y_top - HEAD_H / 2, name, va="center", ha="left", fontsize=10.5,
            fontweight="bold", color=INK, family="monospace", zorder=4)
    if spec.get("note"):
        ax.text(x + w - 0.16, y_top - HEAD_H / 2, spec["note"], va="center", ha="right",
                fontsize=6.4, color=CK_C, family="monospace", fontweight="bold", zorder=4)

    for i, (kind, col, typ) in enumerate(cols):
        yy = y_top - HEAD_H - ROW_H * (i + 0.5)
        colour = {"PK": PK_C, "FK": FK_C, "UX": PK_C, "CK": CK_C}.get(kind, MUTED)
        if kind:
            ax.text(x + 0.16, yy, kind, va="center", ha="left", fontsize=6.2,
                    color=colour, family="monospace", fontweight="bold", zorder=4)
        ax.text(x + 0.56, yy, col, va="center", ha="left", fontsize=7.8,
                color=INK if kind in ("PK", "UX") else "#31404e", family="monospace",
                fontweight="bold" if kind in ("PK", "UX") else "normal", zorder=4)
        ax.text(x + w - 0.16, yy, typ, va="center", ha="right", fontsize=6.4,
                color=MUTED, family="monospace", zorder=4)
    spec["_box"] = (x, y_bot, w, h)


def arrow(ax, p0, p1, colour, style="-", lw=1.4, rad=0.0):
    ax.add_patch(FancyArrowPatch(
        p0, p1, connectionstyle=f"arc3,rad={rad}",
        arrowstyle="-|>,head_width=4,head_length=8", linewidth=lw, color=colour,
        linestyle=style, zorder=5, shrinkA=3, shrinkB=3, mutation_scale=1.0))


def tag(ax, xy, text, colour, fontsize=6.8):
    ax.text(*xy, text, fontsize=fontsize, color=colour, family="monospace",
            ha="center", va="center", zorder=6, linespacing=1.5,
            bbox=dict(boxstyle="round,pad=0.3", facecolor=BG, edgecolor=colour,
                      linewidth=0.8))


fig, ax = plt.subplots(figsize=(W, H), dpi=105)
ax.set_xlim(0, W)
ax.set_ylim(0, H)
ax.axis("off")
fig.patch.set_facecolor(BG)

ax.text(CL, 12.75, "BiteStream - PostgreSQL relational schema", fontsize=18,
        fontweight="bold", color=INK)
ax.text(CL, 12.35, "CS6.302 Assignment 1 - Project 1     "
                   "solid box = base table     dashed box = derived object",
        fontsize=9, color=MUTED)

for name, spec in TABLES.items():
    draw_table(ax, name, spec)

ux, uy, uw, uh = TABLES["users"]["_box"]
wx, wy, ww, wh = TABLES["wallet_audit_logs"]["_box"]
rx, ry, rw, rh = TABLES["restaurants"]["_box"]
ox, oy, ow, oh = TABLES["orders"]["_box"]
mx, my, mw, mh = TABLES["mv_restaurant_performance"]["_box"]

GAP = (ux + uw + wx) / 2          # the empty column between the left and middle tables

# --- the TRIGGER: the edge no auto-generated ERD ever draws --------------------------
# Drawn high, between the two box tops, so it never crosses the foreign-key routing below.
arrow(ax, (ux + uw, R1 - 0.78), (wx, R1 - 0.78), CK_C, style=(0, (5, 3)), lw=2.2)
tag(ax, (GAP, R1 - 1.62),
    "TRIGGER trg_wallet_audit\nAFTER UPDATE OF wallet_balance\n"
    "FOR EACH ROW\nWHEN (OLD IS DISTINCT FROM NEW)", CK_C, 6.9)

# --- FK: wallet_audit_logs.user_id -> users.id ---------------------------------------
# Routed BELOW both boxes (rad dips it into the empty band) so it stays clear of the
# trigger annotation above it.
arrow(ax, (wx + 0.5, wy), (ux + uw * 0.72, uy), FK_C, rad=-0.28)
tag(ax, (GAP, 8.70), "1 : N   FK  ON DELETE RESTRICT", FK_C)

# --- FK: orders.user_id -> users.id ---------------------------------------------------
arrow(ax, (ox + 1.1, oy + oh), (ux + 1.6, uy), FK_C, rad=-0.16)
tag(ax, (GAP - 1.15, 7.65), "1 : N   orders.user_id", FK_C)

# --- FK: orders.restaurant_id -> restaurants.id --------------------------------------
arrow(ax, (ox, oy + oh * 0.55), (rx + rw, ry + rh * 0.55), FK_C)
tag(ax, (GAP, R2 - 0.85), "1 : N\norders.restaurant_id", FK_C)

# --- the materialized view -------------------------------------------------------------
arrow(ax, (mx, my + mh * 0.55), (ox + ow, oy + oh * 0.55), MV_C, style=(0, (4, 3)), lw=1.5)
tag(ax, (CR + WR / 2, my - 0.75),
    "mv_restaurant_performance =\n"
    "restaurants LEFT JOIN orders\n"
    "ON ... AND status = 'DELIVERED'\n"
    "(in ON, never in WHERE)", MV_C)

# --- checkout_attempts note -----------------------------------------------------------
tag(ax, (CR + WR / 2, R1 - 2.95),
    "written by sp_execute_checkout AFTER\n"
    "its COMMIT / ROLLBACK, which is the only\n"
    "reason a failed attempt survives at all", MUTED)

# --- the PARTIAL UNIQUE INDEX ---------------------------------------------------------
pix, piy, piw, pih = CM, 0.55, WM, 1.85
ax.add_patch(FancyBboxPatch(
    (pix, piy), piw, pih, boxstyle="round,pad=0.06,rounding_size=0.08",
    linewidth=1.6, edgecolor=PK_C, facecolor="#eaf0f5", zorder=3))
ax.text(pix + 0.22, piy + pih - 0.30, "PARTIAL UNIQUE INDEX  idx_active_user_order",
        fontsize=7.8, fontweight="bold", color=PK_C, family="monospace",
        va="center", zorder=4)
for i, (line, col) in enumerate([
        ("UNIQUE ON orders (user_id)", INK),
        ("  WHERE status IN ('PREPARING','DELIVERING')", INK),
        ("=> at most ONE active order per user; a 2nd raises 23505", MUTED),
        ("=> DELIVERED rows are not in the index at all", MUTED)]):
    ax.text(pix + 0.22, piy + pih - 0.66 - i * 0.30, line, fontsize=6.6, color=col,
            family="monospace", va="center", zorder=4)
arrow(ax, (pix + piw / 2, piy + pih), (ox + ow / 2, oy), PK_C, lw=1.5)

# --- legend ----------------------------------------------------------------------------
lx, ly = CL, 0.55
ax.add_patch(FancyBboxPatch(
    (lx, ly), WL, 1.85, boxstyle="round,pad=0.06,rounding_size=0.08",
    linewidth=1.0, edgecolor=LINE, facecolor="#f7f9fa", zorder=3))
ax.text(lx + 0.22, ly + 1.55, "LEGEND", fontsize=7.4, fontweight="bold", color=INK,
        family="monospace", va="center", zorder=4)
for i, (c, t) in enumerate([
        (PK_C, "PK / UX   primary or unique key"),
        (FK_C, "FK        foreign key  (solid arrow)"),
        (CK_C, "CK        CHECK constraint"),
        (CK_C, "- - -     trigger (red dashes)"),
        (MV_C, "- - -     feeds the mat. view (green)")]):
    yy = ly + 1.25 - i * 0.26
    ax.text(lx + 0.28, yy, "■", fontsize=8, color=c, va="center", zorder=4)
    ax.text(lx + 0.58, yy, t, fontsize=6.6, color=MUTED, va="center",
            family="monospace", zorder=4)

fig.savefig(OUT, dpi=105, bbox_inches="tight", facecolor=BG)
print(f"wrote {OUT} ({OUT.stat().st_size / 1024:.0f} KB)")
