FROM docker:stable

LABEL "name"="industrial_ci Action"
LABEL "com.github.actions.name"="GitHub Action for industrial Ci"
LABEL "com.github.actions.icon"="package"
LABEL "com.github.actions.color"="blue"

RUN mkdir /ici && apk --no-cache add bash coreutils
COPY README.rst industrial_ci/src/ /ici/

ENTRYPOINT ["/ici/github_action.sh"]
