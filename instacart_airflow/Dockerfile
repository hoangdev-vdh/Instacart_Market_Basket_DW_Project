FROM apache/airflow:3.2.1

# Cài đặt thư viện lõi của hệ điều hành để chạy được ODBC
USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
         build-essential \
         unixodbc-dev \
         curl \
         gnupg2 \
  && curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - \
  && curl https://packages.microsoft.com/config/debian/12/prod.list > /etc/apt/sources.list.d/mssql-release.list \
  && apt-get update \
  && ACCEPT_EULA=Y apt-get install -y msodbcsql17 \
  && apt-get autoremove -yqq --purge \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Cài đặt thư viện Python cho DAG
USER airflow
RUN pip install --no-cache-dir \
    "apache-airflow-providers-microsoft-mssql" \
    "pyodbc" \
    "pandas" \
    "sqlalchemy"