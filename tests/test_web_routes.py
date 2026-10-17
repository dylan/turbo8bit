"""Smoke tests for the public site and its shared navigation/SEO contract."""

import json
from pathlib import Path
from xml.etree import ElementTree

import pytest

from web import main


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setitem(main.app.config, "TESTING", True)
    monkeypatch.setitem(main.app.config, "SECRET_KEY", "test-only-session-key")
    return main.app.test_client()


@pytest.mark.parametrize(
    "path", ["/", "/asm", "/games", "/hardware", "/memmap", "/sid", "/about"]
)
def test_public_pages_render_with_shared_navigation(client, path):
    response = client.get(path)
    assert response.status_code == 200
    assert response.mimetype == "text/html"
    text = response.get_data(as_text=True)
    assert '<nav class="main-nav" aria-label="Main">' in text
    assert 'aria-current="page"' in text
    assert f'<link rel="canonical" href="{main.CANONICAL_ORIGIN}{path}">' in text
    assert response.headers["X-Content-Type-Options"] == "nosniff"


def test_sitemap_matches_all_public_pages(client):
    response = client.get("/sitemap.xml")
    assert response.status_code == 200
    assert response.mimetype == "application/xml"
    root = ElementTree.fromstring(response.data)
    urls = root.findall("{http://www.sitemaps.org/schemas/sitemap/0.9}url")
    assert len(urls) == len(main.SITE_PAGES)
    locations = {
        url.findtext("{http://www.sitemaps.org/schemas/sitemap/0.9}loc") for url in urls
    }
    with main.app.test_request_context():
        expected = {main.canonical_url_for(page.endpoint) for page in main.SITE_PAGES}
    assert locations == expected


def test_robots_exposes_canonical_sitemap(client):
    response = client.get("/robots.txt")
    assert response.status_code == 200
    assert response.mimetype == "text/plain"
    assert f"Sitemap: {main.CANONICAL_ORIGIN}/sitemap.xml" in response.get_data(
        as_text=True
    )


def test_canonical_redirect_preserves_path_and_query(client):
    response = client.get("/asm?example=hello", base_url="https://alternate.example")
    assert response.status_code == 301
    assert response.headers["Location"] == f"{main.CANONICAL_ORIGIN}/asm?example=hello"


def test_sign_in_without_credential_is_rejected(client):
    response = client.post("/auth/google")
    assert response.status_code == 400


def test_logout_clears_session(client):
    with client.session_transaction() as session:
        session["user_email"] = "test@example.com"
    response = client.get("/auth/logout")
    assert response.status_code == 302
    assert response.headers["Location"] == "/"
    with client.session_transaction() as session:
        assert "user_email" not in session


GAMES_INDEX = Path(main.app.static_folder) / "games" / "index.json"


def test_games_page_is_the_assembly_lab_set_up_for_games(client):
    text = client.get("/games").get_data(as_text=True)
    assert 'data-library="/static/games/index.json"' in text
    assert 'data-joystick="2"' in text
    assert "data-reset-on-run" in text
    games = json.loads(GAMES_INDEX.read_text(encoding="utf-8"))["examples"]
    for game in games:
        assert f'data-sample="{game["id"]}"' in text
        assert f"runSample('{game['id']}')" in text


def test_assembly_page_keeps_its_own_samples(client):
    text = client.get("/asm").get_data(as_text=True)
    assert '<div class="c64-page" id="asmLab">' in text
    assert "game-card" not in text
