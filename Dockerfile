# Claims Desk middleware and document service for stage 4 (API pods on NKP).
# One image, two commands: the Helm chart runs claimsdesk.api and claimsdesk.docs
# as two containers in the same pod.
#
#   docker build -t ghcr.io/apjgase/claims-desk-demo:<version> .
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/claims-desk/app

COPY app/requirements.txt app/constraints.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt -c /tmp/constraints.txt \
 && rm -f /tmp/requirements.txt /tmp/constraints.txt

COPY app /opt/claims-desk/app
RUN python -m compileall -q /opt/claims-desk/app \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin claimsdesk

WORKDIR /opt/claims-desk/app
# The chart sets runAsUser to the document VM's claimsdesk uid so NFSv3 writes match.
USER 10001
EXPOSE 8000 8090
CMD ["uvicorn", "claimsdesk.api:app", "--host", "0.0.0.0", "--port", "8000", "--no-server-header"]
