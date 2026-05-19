from fastapi.testclient import TestClient

from api.main import app

client = TestClient(app)


def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_create_and_list_tasks():
    # create task
    payload = {"title": "Test task", "description": "desc", "status": "pending"}
    create_resp = client.post("/tasks", json=payload)
    assert create_resp.status_code == 201
    data = create_resp.json()
    assert data["title"] == "Test task"
    assert data["status"] == "pending"
    assert "id" in data

    # list tasks
    list_resp = client.get("/tasks")
    assert list_resp.status_code == 200
    tasks = list_resp.json()
    assert len(tasks) >= 1


def test_get_update_delete_task():
    # create task
    payload = {"title": "To update", "description": None, "status": "pending"}
    create_resp = client.post("/tasks", json=payload)
    task = create_resp.json()
    task_id = task["id"]

    # get task
    get_resp = client.get(f"/tasks/{task_id}")
    assert get_resp.status_code == 200
    assert get_resp.json()["id"] == task_id

    # update task
    update_payload = {"title": "Updated", "status": "done"}
    update_resp = client.put(f"/tasks/{task_id}", json=update_payload)
    assert update_resp.status_code == 200
    updated = update_resp.json()
    assert updated["title"] == "Updated"
    assert updated["status"] == "done"

    # delete task
    delete_resp = client.delete(f"/tasks/{task_id}")
    assert delete_resp.status_code == 204

    # ensure not found afterwards
    get_resp2 = client.get(f"/tasks/{task_id}")
    assert get_resp2.status_code == 404