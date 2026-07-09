// CI for the 9cc CLI. Runs on the Ubuntu Jenkins server.
//
// Why this exists: a previous bug shipped `9cc update` broken because macOS
// `base64 -d` rejects line-wrapped base64 while Linux tolerates it. A
// Linux-only CI cannot catch that — so the unit stage runs the tests with a
// shimmed `base64` that mimics macOS strictness (see Cycle 14c), AND a real
// macOS node is attempted in the matrix stage.
//
// IVT-0610.
pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 15, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    environment {
        // Hermetic: unit tests + smoke must never depend on the host's ~/.9cc.
        CC9_HOME = "${env.WORKSPACE}/.ci-home"
        CC9_BIN_DIR = "${env.WORKSPACE}/.ci-bin"
    }

    stages {

        stage('Unit tests (Linux, macOS-strict decode)') {
            steps {
                sh '''
                    set -e
                    mkdir -p "$CC9_HOME" "$CC9_BIN_DIR"
                    # Smoke-check the launcher parses before exercising it.
                    bash -n 9cc/9cc.sh
                    bash -n 9cc/smoke.sh
                    bash 9cc/9cc.test.sh
                '''
            }
        }

        stage('Smoke test (update path)') {
            steps {
                sh '''
                    set -e
                    bash 9cc/smoke.sh
                '''
            }
        }

        stage('Matrix: real macOS') {
            // The Jenkins fleet today is Ubuntu-only, so there is no `macos`
            // agent to schedule on. This stage is defined so that as soon as a
            // macOS agent (label `macos`) is added, real macOS coverage is
            // automatic — no pipeline edit needed. Until then it is skipped
            // rather than failing the build.
            steps {
                script {
                    def macAgent = nodesByLabel label: 'macos'
                    if (macAgent) {
                        node('macos') {
                            sh '''
                                set -e
                                bash 9cc/9cc.test.sh
                                bash 9cc/smoke.sh
                            '''
                        }
                    } else {
                        echo 'IVT-0610: no `macos` Jenkins agent yet — skipping real macOS run. ' +
                             'The Linux stage already runs the macOS-strict base64 shim (Cycle 14c) ' +
                             'so the original update-decode regression is covered. Add a macos-labeled ' +
                             'agent to enable native runs.'
                    }
                }
            }
        }
    }

    post {
        always {
            sh 'rm -rf "$CC9_HOME" "$CC9_BIN_DIR" || true'
        }
        unsuccessful {
            echo '9cc CI failed. Run locally: bash 9cc/9cc.test.sh && bash 9cc/smoke.sh'
        }
    }
}
