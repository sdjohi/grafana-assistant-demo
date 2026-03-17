FROM grafana/alloy:v1.14.0

COPY certs/netskope.cer /usr/local/share/ca-certificates/netskope.crt
COPY certs/sd.dika.be.cer /usr/local/share/ca-certificates/sd.dika.be.crt
RUN update-ca-certificates
