FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends wget unzip ca-certificates git \
    libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libgl1 libasound2 libfontconfig1 libudev1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . /app
ENV PYTHONUNBUFFERED=1 SECS=10800
CMD ["python3", "train/railway_main.py"]
