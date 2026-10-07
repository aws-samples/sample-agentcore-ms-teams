FROM public.ecr.aws/docker/library/node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
ARG CACHEBUST=1
COPY dist/ dist/
COPY public/ public/

# Run as the image's built-in non-root `node` user (UID 1000) to limit the
# blast radius of a container compromise.
RUN chown -R node:node /app
USER node

EXPOSE 3981

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "const s=require('net').connect(3981,'127.0.0.1');s.on('connect',()=>{s.end();process.exit(0)});s.on('error',()=>process.exit(1))"

CMD ["node", "dist/index.js"]
