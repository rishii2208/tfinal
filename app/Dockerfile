###############################################
# BASE IMAGE
###############################################
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

###############################################
# SYSTEM DEPENDENCIES
###############################################
RUN apt-get update && apt-get install -y \
    git \
    python3 \
    python3-pip \
    python3-setuptools \
    python-is-python3 \
    unzip \
    curl \
    && rm -rf /var/lib/apt/lists/*

###############################################
# NODE.JS (for frontend)
###############################################
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

###############################################
# PYTHON DEPENDENCIES (backend)
###############################################
RUN pip3 install Flask==3.0.0 Flask-SQLAlchemy==3.1.1 flask-cors==4.0.0 pytest==7.4.4

###############################################
# FRONTEND DEPENDENCIES
###############################################
RUN mkdir -p /frontend-deps \
    && echo '{"name":"soap-production-frontend","version":"1.0.0","private":true,"dependencies":{"react":"^18.2.0","react-dom":"^18.2.0","react-router-dom":"^6.20.0","react-scripts":"5.0.1"}}' > /frontend-deps/package.json \
    && cd /frontend-deps && npm install --legacy-peer-deps

###############################################
# WORKING DIRECTORY + GIT SETUP
###############################################
WORKDIR /app

RUN git init \
    && git config --global user.email "agent@example.com" \
    && git config --global user.name "Agent" \
    && echo "# Workspace" > README.md \
    && git add README.md \
    && git commit -m "Initial commit"

###############################################
# EVALUATION ASSETS DIRECTORY
###############################################
# Populated at RUNTIME by the evaluation script.
RUN mkdir -p /eval_assets

CMD ["/bin/bash"]
