from datetime import datetime
from typing import List

from fastapi import FastAPI, HTTPException

from schemas import Task, TaskCreate, TaskUpdate

app = FastAPI()

tasks: list[Task] = []
_next_id = 1


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/tasks", response_model=List[Task])
def list_tasks():
    return tasks


@app.post("/tasks", response_model=Task, status_code=201)
def create_task(task_in: TaskCreate):
    global _next_id

    now = datetime.utcnow()
    task = Task(
        id=_next_id,
        title=task_in.title,
        description=task_in.description,
        status=task_in.status,
        created_at=now,
        updated_at=now,
    )
    tasks.append(task)
    _next_id += 1
    return task


@app.get("/tasks/{task_id}", response_model=Task)
def get_task(task_id: int):
    for task in tasks:
        if task.id == task_id:
            return task
    raise HTTPException(status_code=404, detail="Task not found")


@app.put("/tasks/{task_id}", response_model=Task)
def update_task(task_id: int, task_in: TaskUpdate):
    for index, task in enumerate(tasks):
        if task.id == task_id:
            data = task.dict()
            if task_in.title is not None:
                data["title"] = task_in.title
            if task_in.description is not None:
                data["description"] = task_in.description
            if task_in.status is not None:
                data["status"] = task_in.status

            data["updated_at"] = datetime.utcnow()
            updated_task = Task(**data)
            tasks[index] = updated_task
            return updated_task

    raise HTTPException(status_code=404, detail="Task not found")


@app.delete("/tasks/{task_id}", status_code=204)
def delete_task(task_id: int):
    for index, task in enumerate(tasks):
        if task.id == task_id:
            tasks.pop(index)
            return
    raise HTTPException(status_code=404, detail="Task not found")