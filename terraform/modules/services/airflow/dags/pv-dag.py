import os
from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.amazon.aws.operators.ecs import EcsRunTaskOperator
from airflow.decorators import dag

from airflow.operators.latest_only import LatestOnlyOperator

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime.utcnow() - timedelta(hours=0.5),
    'retries': 1,
    'retry_delay': timedelta(minutes=1),
    'max_active_runs':10,
    'concurrency':10,
    'max_active_tasks':10,
}

env = os.getenv("ENVIRONMENT","development")
subnet = os.getenv("ECS_SUBNET")
security_group = os.getenv("ECS_SECURITY_GROUP")
cluster = f"Nowcasting-{env}"

# Tasks can still be defined in terraform, or defined here


with DAG('pv-consumer', schedule_interval="*/5 * * * *", default_args=default_args, concurrency=10, max_active_tasks=10) as dag:
    dag.doc_md = "Get PV data"

    latest_only = LatestOnlyOperator(task_id="latest_only")

    pv_consumer = EcsRunTaskOperator(
        task_id='pv-consumer',
        task_definition="pv",
        cluster=cluster,
        overrides={},
        launch_type = "FARGATE",
        network_configuration={
            "awsvpcConfiguration": {
                "subnets": [subnet],
                "securityGroups": [security_group],
                "assignPublicIp": "ENABLED",
            },
        },
     task_concurrency = 10,
    )

    latest_only >> pv_consumer

