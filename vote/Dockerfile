FROM python:3.12-slim
WORKDIR /sources/frontend
COPY requirements.txt . 
RUN pip install -r requirements.txt
COPY . .
CMD ["gunicorn", "--bind", "0.0.0.0:80", "app:app"]