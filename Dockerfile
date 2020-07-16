FROM mongo:latest

# replace present db with our updated populated db 
RUN rm -rf /data/db/*
COPY db /data/db

ENTRYPOINT [ "docker-entrypoint.sh" ]

EXPOSE 27017
CMD ["mongod"]